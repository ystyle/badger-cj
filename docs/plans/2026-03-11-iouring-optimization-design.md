# io_uring I/O 优化设计

**日期**: 2026-03-11
**状态**: 📋 待审核
**优先级**: P2（可选优化）
**预计时间**: 20-30h

---

## 1. 背景

### 1.1 当前 I/O 实现

当前 badger-cj 使用标准文件 I/O：

| 模块 | 实现 | 瓶颈 |
|------|------|------|
| WAL 写入 | `BufferedOutputStream` | 用户态缓冲 + 同步 write() |
| SSTable 写入 | `FileOutputStream` | 同步 write() |
| SSTable 读取 | `FileInputStream` | 同步 read() |
| VLog 写入 | `FileOutputStream` | 同步 write() |

**问题**：
1. 每次 `write()` 都是系统调用，开销 ~1μs
2. 用户态缓冲（BufferedOutputStream）减少系统调用，但增加内存拷贝
3. 无法利用 Linux 5.1+ 的异步 I/O 能力

### 1.2 io_uring 简介

Linux 5.1 引入的高性能异步 I/O 接口：

**核心优势**：
- **零拷贝**：用户态直接读写内核共享的环形缓冲区
- **批处理**：一次系统调用提交多个 I/O 请求
- **异步**：提交后立即返回，完成时通知
- **无锁**：使用内存屏障而非锁实现生产者-消费者

**性能对比**（参考数据）：

| 场景 | sync I/O | libaio | io_uring |
|------|----------|--------|----------|
| 4KB 随机写 | ~10μs | ~8μs | ~2μs |
| 4KB 随机读 | ~15μs | ~10μs | ~3μs |
| 批量 100 写 | ~1000μs | ~800μs | ~50μs |

### 1.3 Go BadgerDB 的 I/O

Go BadgerDB 没有使用 io_uring，但：
- Go runtime 有高效的 netpoller
- Go 的文件 I/O 也是同步的（带缓冲）
- 仓颉目前没有类似的异步 I/O 运行时支持

**结论**：使用 io_uring 可以让仓颉版在 I/O 密集场景超越 Go 版本。

---

## 2. 设计目标

### 2.1 功能目标

1. **可选特性**：通过 feature flag 启用，不影响默认构建
2. **接口兼容**：对上层 DB API 无感知
3. **优雅降级**：io_uring 不可用时自动回退到标准 I/O
4. **Linux only**：仅 Linux 5.1+ 支持

### 2.2 性能目标

| 指标 | 当前 | 目标 |
|------|------|------|
| WAL 写入延迟 | ~50μs | ~10μs |
| SSTable flush 延迟 | ~500μs/MB | ~100μs/MB |
| 批量写入吞吐 | ~20MB/s | ~100MB/s |

### 2.3 约束条件

1. **平台限制**：仅 Linux 5.1+，其他平台自动禁用
2. **依赖增加**：需要 liburing（系统库）
3. **代码复杂度**：FFI 调用 + 异步状态管理
4. **测试成本**：需要 CI 环境支持 io_uring

---

## 3. 详细方案

### 3.1 架构设计

```
┌─────────────────────────────────────────────────────────────┐
│                     DB API (无感知)                          │
├─────────────────────────────────────────────────────────────┤
│  FileWriter 接口                                             │
│  ├── BufferedFileWriter (默认实现)                          │
│  └── IoUringWriter (feature=io_uring)                       │
├─────────────────────────────────────────────────────────────┤
│  FileReader 接口                                             │
│  ├── BufferedFileReader (默认实现)                          │
│  └── IoUringFileReader (feature=io_uring)                   │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 接口定义

```cangjie
// src/db/file_io.cj
public interface FileWriter {
    func write(data: Array<Byte>): Unit
    func sync(): Unit
    func close(): Unit
    func flush(): Unit
}

public interface FileReader {
    func read(buf: Array<Byte>, offset: Int64): Int64
    func readFully(buf: Array<Byte>, offset: Int64): Unit
    func close(): Unit
}

// 工厂方法
public func createWriter(path: String): FileWriter {
    @When[feature == "io_uring"]
    if (IoUringHelper.isAvailable()) {
        return IoUringWriter(path)
    }
    return BufferedFileWriter(path)
}
```

### 3.3 io_uring FFI 绑定

```cangjie
// src/db/io_uring.cj
@When[feature == "io_uring"]
package badgercj.db.io_uring

// liburing 核心结构
@C
struct io_uring {
    // 不透明结构，仅用于指针传递
}

@C
struct io_uring_sqe {  // Submission Queue Entry
    var opcode: UInt8
    var flags: UInt8
    var ioprio: UInt16
    var fd: Int32
    var off: UInt64
    var addr: UInt64
    var len: UInt32
    // ... 其他字段
}

@C
struct io_uring_cqe {  // Completion Queue Entry
    var userData: UInt64
    var res: Int32
    var flags: UInt32
}

// liburing FFI 声明
foreign func io_uring_queue_init(entries: UInt32, ring: CPointer<io_uring>, flags: UInt32): Int32
foreign func io_uring_queue_exit(ring: CPointer<io_uring>): Unit
foreign func io_uring_get_sqe(ring: CPointer<io_uring>): CPointer<io_uring_sqe>
foreign func io_uring_submit(ring: CPointer<io_uring>): Int32
foreign func io_uring_wait_cqe(ring: CPointer<io_uring>, cqePtr: CPointer<CPointer<io_uring_cqe>>): Int32
foreign func io_uring_cqe_seen(ring: CPointer<io_uring>, cqe: CPointer<io_uring_cqe>): Unit

// 便捷函数
foreign func io_uring_prep_writev(sqe: CPointer<io_uring_sqe>, fd: Int32, iovecs: CPointer<iovec>, nr_vecs: UInt32, offset: UInt64): Unit
foreign func io_uring_prep_readv(sqe: CPointer<io_uring_sqe>, fd: Int32, iovecs: CPointer<iovec>, nr_vecs: UInt32, offset: UInt64): Unit
foreign func io_uring_prep_fsync(sqe: CPointer<io_uring_sqe>, fd: Int32, fsync_flags: UInt32): Unit

// iovec 结构
@C
struct iovec {
    var iovBase: CPointer<Unit>
    var iovLen: UIntNative
}
```

### 3.4 IoUringWriter 实现

```cangjie
@When[feature == "io_uring"]
public class IoUringWriter <: FileWriter {
    private let ring: CPointer<io_uring>
    private let fd: Int32
    private let path: String
    private var offset: UInt64 = 0
    private var pendingOps: Int32 = 0
    
    public init(path: String) {
        this.path = path
        this.ring = unsafe { LibC.malloc<io_uring>() }
        
        // 初始化 io_uring，队列深度 256
        let ret = unsafe { io_uring_queue_init(256, ring, 0) }
        if (ret < 0) {
            throw IoUringException("io_uring_queue_init failed: ${ret}")
        }
        
        // 打开文件
        this.fd = unsafe { open(path, O_WRONLY | O_CREAT | O_DIRECT, 0644) }
        if (fd < 0) {
            throw IoException("Failed to open file: ${path}")
        }
    }
    
    public func write(data: Array<Byte>): Unit {
        unsafe {
            // 获取 SQE
            let sqe = io_uring_get_sqe(ring)
            if (sqe.isNull()) {
                // 队列满，等待完成
                waitForCompletion()
                write(data)
                return
            }
            
            // 准备 writev
            var iov = iovec()
            iov.iovBase = CPointer<Unit>(data.asBuffer())
            iov.iovLen = data.size
            
            io_uring_prep_writev(sqe, fd, inout iov, 1, offset)
            sqe.userData = offset  // 用于完成时识别
            
            offset += data.size
            pendingOps++
            
            // 批量提交
            if (pendingOps >= 16) {
                io_uring_submit(ring)
                pendingOps = 0
            }
        }
    }
    
    public func sync(): Unit {
        unsafe {
            let sqe = io_uring_get_sqe(ring)
            io_uring_prep_fsync(sqe, fd, IORING_FSYNC_DATASYNC)
            io_uring_submit_and_wait(ring, 1)
        }
    }
    
    public func close(): Unit {
        unsafe {
            // 等待所有完成
            while (pendingOps > 0) {
                waitForCompletion()
            }
            io_uring_queue_exit(ring)
            close(fd)
            LibC.free(ring)
        }
    }
    
    private func waitForCompletion(): Unit {
        unsafe {
            var cqe = CPointer<io_uring_cqe>()
            io_uring_wait_cqe(ring, inout cqe)
            if (cqe.res < 0) {
                throw IoUringException("I/O error: ${cqe.res}")
            }
            io_uring_cqe_seen(ring, cqe)
            pendingOps--
        }
    }
}
```

### 3.5 编译配置

**cjpm.toml**:
```toml
[package]
  name = "badgercj"
  version = "1.0.0"
  
[target.x86_64-unknown-linux-gnu]
  compile-option = '--cfg "feature=io_uring"'
  link-option = "-luring"  # 链接 liburing
```

**cfg.toml**（可选，放在项目根目录）:
```toml
feature = "io_uring"
```

**编译命令**:
```shell
# 启用 io_uring
cjpm build --cfg "feature=io_uring"

# 不启用（默认）
cjpm build
```

---

## 4. 实现任务

### Phase 1: 基础设施 (~8h)

| 任务 | 预估 | 说明 |
|------|------|------|
| FFI 绑定 | 2h | io_uring 核心结构和函数 |
| 单元测试 | 2h | 基本 read/write/ sync |
| 平台检测 | 2h | 运行时检测 io_uring 可用性 |
| 错误处理 | 2h | 异常类型和错误传播 |

### Phase 2: FileWriter 实现 (~6h)

| 任务 | 预估 | 说明 |
|------|------|------|
| IoUringWriter | 3h | 基本写入实现 |
| 批量写入优化 | 2h | writev 批量提交 |
| WAL 集成 | 1h | 替换 BufferedOutputStream |

### Phase 3: FileReader 实现 (~6h)

| 任务 | 预估 | 说明 |
|------|------|------|
| IoUringReader | 3h | 基本读取实现 |
| 预读优化 | 2h | 异步预读下一个 block |
| SSTable 集成 | 1h | 替换 FileInputStream |

### Phase 4: 测试与优化 (~6h)

| 任务 | 预估 | 说明 |
|------|------|------|
| 集成测试 | 2h | DB 级别测试 |
| 性能基准 | 2h | 对比标准 I/O |
| 内存优化 | 2h | 减少拷贝、缓冲区复用 |

---

## 5. 风险与缓解

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|---------|
| liburing 版本兼容 | 中 | 中 | 检测版本，必要时禁用 |
| O_DIRECT 对齐要求 | 高 | 低 | 使用对齐分配器 |
| io_uring 内核 bug | 低 | 高 | 提供 disable 选项 |
| FFI 内存安全 | 中 | 高 | 充分测试，unsafe 边界清晰 |
| CI 不支持 io_uring | 中 | 低 | 条件编译跳过测试 |

---

## 6. 验收标准

### 功能验收

- [ ] io_uring 可用时自动启用
- [ ] io_uring 不可用时自动降级
- [ ] 所有现有测试通过
- [ ] 新增 io_uring 专项测试

### 性能验收

- [ ] WAL 写入延迟降低 50%+
- [ ] 批量写入吞吐提升 3x+
- [ ] 无性能回退（禁用时）

### 质量验收

- [ ] FFI 代码有充分注释
- [ ] 错误处理完整
- [ ] 文档更新

---

## 7. 参考资料

- [io_uring 系统调用文档](https://man7.org/linux/man-pages/man7/io_uring.7.html)
- [liburing GitHub](https://github.com/axboe/liburing)
- [Efficient IO with io_uring (PDF)](https://kernel.dk/io_uring.pdf)
- [仓颉 FFI 文档](manual/source_zh_cn/FFI/cangjie-c.md)

---

## 8. 待讨论事项

1. **队列深度选择**：256 是否合适？需要根据实际负载调整
2. **O_DIRECT 是否启用**：避免双缓冲但要求对齐，增加复杂度
3. **是否支持 io_uring 的 polling 模式**：更低延迟但更高 CPU
4. **Windows/macOS 替代方案**：是否需要基于 IOCP/kqueue 的实现
5. **与异步运行时集成**：未来是否需要 async/await 支持

---

## 9. 时间线（待定）

| 阶段 | 预计时间 | 里程碑 |
|------|----------|--------|
| Phase 1 | 第 1-2 周 | FFI 绑定 + 基础测试 |
| Phase 2 | 第 3 周 | FileWriter 完成 |
| Phase 3 | 第 4 周 | FileReader 完成 |
| Phase 4 | 第 5 周 | 测试与优化 |
| **总计** | **5 周** | **io_uring 优化完成** |

---

**文档版本**: v1.0
**创建日期**: 2026-03-11
**最后更新**: 2026-03-11
**状态**: 📋 待审核
