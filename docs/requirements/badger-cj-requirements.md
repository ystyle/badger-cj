# badgercj 需求文档

## 项目概述

**项目名称：** badgercj  
**包名：** badgercj  
**GitHub 仓库：** badger-cj  

**项目定位：** BadgerDB 的仓颉语言移植版本，一个嵌入式、持久化、高性能的键值数据库。

**核心特性：**
- 持久化 KV 存储（非内存数据库）
- 文件格式与 Go BadgerDB 完全兼容
- 支持 ACID 事务
- 针对 SSD 优化

## 目标与范围

### 核心目标

1. **数据兼容性**：与 Go BadgerDB v4 实现字节级文件格式兼容
2. **功能完整性**：实现核心 KV 功能和事务支持
3. **性能目标**：达到 Go 版本性能的 80% 以上
4. **易用性**：提供符合仓颉语言习惯的 API

### 功能范围

#### P0 - 必须实现（MVP）

**基础 KV 操作**
- `Get(key) -> Option<Value>`
- `Set(key, value)`
- `Delete(key)`
- `Has(key) -> Bool`

**LSM Tree 核心**
- MemTable（基于 Skiplist）
- Immutable MemTable
- Level 0-6 的 SSTable 管理
- 自动 Flush（MemTable → SSTable）

**存储引擎**
- SSTable (.sst) 文件读写
- Value Log (.vlog) 文件读写
- MANIFEST 文件管理
- Bloom Filter 优化

**事务支持**
- ACID 事务
- SSI (Serializable Snapshot Isolation)
- 读写冲突检测
- 事务回滚

#### P1 - 重要功能

**快照与迭代**
- Snapshot（快照读）
- Iterator（正向/反向遍历）
- Prefix 扫描
- 范围查询

**压缩与清理**
- Compaction（自动压缩）
- Value Log GC（垃圾回收）
- TTL 支持（过期时间）

**性能优化**
- Block Cache
- Index Cache
- 并发控制

#### P2 - 暂不实现（后续版本）

- 加密（Encryption at Rest）
- Stream Writer（流式写入）
- Backup/Restore（备份恢复）
- Merge Operator（合并操作符）
- Managed DB（版本管理）
- 分布式特性

## 非功能需求

### 性能要求

**写入性能：**
- 顺序写入：≥ 100,000 ops/sec
- 随机写入：≥ 50,000 ops/sec
- 批量写入：≥ 200,000 ops/sec

**读取性能：**
- 随机读取：≥ 80,000 ops/sec
- 范围扫描：≥ 500,000 keys/sec
- 点查询（带 Bloom Filter）：≥ 150,000 ops/sec

**性能对比目标（相对于 Go 版本）：**
- 写入吞吐：≥ 80%
- 读取延迟：≤ 120%
- 内存占用：≤ 110%

### 可靠性要求

**数据持久性：**
- 支持文件系统 sync/fsync
- 进程崩溃后数据不丢失
- 支持事务回滚

**错误处理：**
- 所有 I/O 操作返回 Result<T, Error>
- 提供详细的错误信息
- 支持错误恢复

### 兼容性要求

**文件格式兼容：**
- 完全兼容 BadgerDB v4 的文件格式
- 支持读写 Go 版本创建的数据文件
- 字节级兼容（CRC32、序列化格式）

**数据格式：**
- Key: `Array<Byte>`（支持任意字节序列）
- Value: `Array<Byte>`（支持任意字节序列）
- 最大 Key 长度：64KB
- 最大 Value 长度：4GB

### 可维护性要求

**代码质量：**
- 代码覆盖率 ≥ 70%
- 关键路径有性能测试
- API 文档完整

**模块化设计：**
- 清晰的模块边界
- 最小化依赖关系
- 易于测试

## 技术约束

### 语言特性

**仓颉语言限制：**
- 无 `unsafe.Pointer` → 使用整数偏移量代替
- 无直接内存映射 → 使用 File + Array<Byte> 模拟
- 无泛型 → 使用接口或代码生成

**依赖管理：**
- 最小化外部依赖
- 优先使用仓颉标准库
- 压缩算法可选：纯仓颉实现或 FFI 调用 C 库

### 平台支持

**目标平台：**
- Linux (x86_64, ARM64)
- macOS (x86_64, ARM64)
- Windows (可选)

**文件系统：**
- 支持 POSIX 文件系统
- 支持目录锁定
- 支持 fsync/fdatasync

## API 设计原则

### 易用性

```cangjie
// 简单的打开/关闭
let db = DB.open("/path/to/db")?
defer { db.close() }

// 直观的 KV 操作
db.set("key", "value")?
let val = db.get("key")?
db.delete("key")?

// 事务支持
db.transaction { txn =>
    txn.set("k1", "v1")
    txn.set("k2", "v2")
    // 自动提交或回滚
}
```

### 仓颉惯用法

```cangjie
// 使用 Option/Result 而非异常
func get(key: Array<Byte>): Option<Array<Byte>>

// 使用泛型而非 interface{}
class Cache<K, V> where K: Hashable, K: Equatable

// 使用资源管理（类似 Python with）
let db = DB.open(options)  // RAII 自动关闭
```

### 配置灵活

```cangjie
let options = DBOptions(
    dir: "/data/db",
    valueDir: "/data/db/values",
    syncWrites: false,
    numLevelZeroTables: 5,
    blockSize: 4 * 1024,
    bloomFalsePositive: 0.01,
    compression: CompressionType.Snappy
)

let db = DB.open(options)?
```

## 质量保证

### 测试策略

**单元测试：**
- 每个模块独立测试
- 边界条件覆盖
- 错误路径测试

**集成测试：**
- 端到端功能测试
- 并发场景测试
- 崩溃恢复测试

**兼容性测试：**
- 读取 Go 版本数据
- 写入数据供 Go 版本读取
- 混合读写测试

**性能测试：**
- 基准测试（benchmark）
- 对比 Go 版本性能
- 压力测试

### 验收标准

**功能验收：**
- [ ] 所有 P0 功能实现并通过测试
- [ ] 所有 P1 功能实现并通过测试
- [ ] 文件格式兼容性测试通过

**性能验收：**
- [ ] 写入性能达标
- [ ] 读取性能达标
- [ ] 内存占用达标

**质量验收：**
- [ ] 代码覆盖率 ≥ 70%
- [ ] 所有测试通过
- [ ] 无已知严重 bug

## 里程碑规划

### Phase 1: 基础设施（2 周）
- Arena 内存分配器
- Varint 编解码
- 文件 I/O 封装
- CRC32 校验

### Phase 2: 存储引擎（3 周）
- Skiplist 实现
- SSTable 读写
- Value Log 读写
- MANIFEST 管理

### Phase 3: 核心功能（3 周）
- DB 主类
- LSM Tree 管理
- 基础 KV 操作
- Compaction

### Phase 4: 事务支持（2 周）
- 事务实现
- Iterator
- Snapshot

### Phase 5: 优化与测试（2 周）
- 性能优化
- 兼容性测试
- 文档完善

**预计总工期：12 周**

## 风险与缓解

### 技术风险

**风险 1：仓颉语言特性限制**
- 缓解：使用整数偏移量代替指针
- 缓解：手动管理内存布局

**风险 2：性能不达标**
- 缓解：先保证正确性，后优化性能
- 缓解：使用性能分析工具定位瓶颈

**风险 3：文件格式兼容性问题**
- 缓解：逐字节对比 Go 版本输出
- 缓解：编写兼容性测试套件

### 项目风险

**风险 4：工作量估算不准确**
- 缓解：采用迭代开发，及时调整
- 缓解：先实现 MVP，再逐步完善

## 知识产权声明

本项目是 BadgerDB 的仓颉语言移植版本，遵循 Apache 2.0 许可证。

**原创项目：**
- BadgerDB - Copyright © 2017-2025 Istari Digital, Inc.
- 基于 WiscKey 论文实现

**商标声明：**
- "BadgerDB" 是 Dgraph Labs, Inc. 的商标
- 本项目与 Dgraph Labs 无官方关联
- 本项目非官方版本，为社区驱动的移植版本

## 参考资料

**设计论文：**
- [WiscKey: Separating Keys from Values in SSD-conscious Storage](https://www.usenix.org/system/files/conference/fast16/fast16-papers-lu.pdf)

**原始实现：**
- [BadgerDB GitHub](https://github.com/dgraph-io/badger)

**相关文档：**
- LSM Tree 原理
- Skiplist 算法
- 事务隔离级别
