# Badger-cj v2.0：WAL / VLog 写路径 mmap 化设计

> 状态：已实现（阶段 1/2/4，v2.0.0；`feat/v2-mmap-wal-vlog` @ ab6f640）
> 目标版本：v2.0.0
> 口径（2026-11-09 更新，与 [`2026-11-09-v2.0-implementation-plan.md`](2026-11-09-v2.0-implementation-plan.md) 一致）：
> ① 本设计只对齐 go 的**语义**，**不追求文件格式字节兼容**（2.0 为自有格式：可读 v1.6.x 目录，不支持降级）；
> ② **加密（Encryption at rest）不进 2.0**，作为 2.1+ 可选能力延后；
> ③ 阶段 3（VLog 读 mmap）并入读路径收口，不作为 2.0 必做项；
> ④ 新增 `<dir>/FORMAT` 格式基线（`format=1`、`features=`），在 2.0.0 落地。
> 关联：`benchmark-report.md` P1 优化项「VLog mmap 替代 BufferedOutputStream」、`mmap-cj`（darwin/linux/windows 三平台封装）、go 版 `z.MmapFile`

## 1. 背景与动机

### 1.1 对齐 go 版写路径

go badger 的持久化写路径使用 **mmap**：

| 写路径 | go badger | badger-cj 现状 |
|--------|-----------|----------------|
| memtable WAL（.mem） | `z.MmapFile`（memtable.go:250/538） | `BufferedOutputStream`（64KB 缓冲普通 write） |
| vlog（.vlog） | mmap 写（value.go:884 "write to file directly via mmap"） | 无缓冲 `File.write`（**每次 syscall**） |
| SSTable | 普通 write | io_uring 批量（Linux）/ 同步降级 |

badger-cj 的 vlog 无缓冲写是已知痛点（v1.6.7 评审为此专门把 vlog.write 移出全局写锁）；WAL 缓冲写有 64KB 缓冲的落盘不确定性（syncWrites=false 时缓冲不满不落盘）。

### 1.2 benchmark 计划

`benchmark-report.md` 明确列出：

| 优先级 | 优化项 | 预期收益 |
|--------|--------|---------|
| P1 | **VLog mmap 替代 BufferedOutputStream** | 减少 I/O 复制，预期 DB Set 减半 |
| P1 | WAL batch write + group commit | 减少 fsync 次数 |

mmap 是 P1 未实现项，且条件已成熟（见 1.4）。

### 1.3 io_uring 的容器限制

Docker 默认 seccomp 拦截 `io_uring_setup`（容器逃逸漏洞 moby#46762，EPERM）——io_uring 仅限 Linux 且容器内不可用（已由 v1.6.9 同步降级兜底）。写路径若完全 mmap 化，**不再依赖 io_uring**，天然全平台（linux/darwin/windows）。

### 1.4 条件成熟

- `mmap-cj` 已发布三平台封装（Linux/macOS `mmap/msync`、Windows `CreateFileMappingW/FlushViewOfFile`）
- GitHub Actions 可跑 arm64 macOS（已实测验证）
- 历史：v1.3.x 时代曾尝试手写 mmap FFI（`mmap_file.cj`）因无成熟封装 + 无法验证 macOS 而放弃——现两个障碍均消除

## 2. 现状分析

### 2.1 写路径全景

```
用户写 → WritePipeline → writeRequests
  ├─ prepareEntries（锁外）：vlog.write（无缓冲 File.write，每次 syscall）
  └─ putPrepared（锁内）：mt.put → WAL.write（BufferedOutputStream 64KB 缓冲）
                            → memtable Skiplist（内存）
memtable 满 → flushMemTableInternal → flushToLevel（内存表）
close/compaction → flushMemTableToDisk → writeFile（io_uring 或同步）→ SSTable
```

### 2.2 关键文件结构

| 文件 | 生命周期 | 大小 |
|------|---------|------|
| WAL `${fid}.mem` | memtable 生命周期（open→flush/close） | ≤ memTableSize 数据量 |
| VLog `${fid}.vlog` | 分段（写满开新文件） | `maxFileSize = 1GB`（vlog_manager.cj:372） |
| SSTable `*.sst` | 持久 | 定长块 |

**关键事实**：vlog 是固定大小分段文件、WAL 每 memtable 一个文件——**文件大小可预分配**，不需要运行中 remap。

## 3. 目标与非目标

### 3.1 目标（v2.0）

1. WAL 写路径 mmap 化：`WAL` 类内部用 mmap 写（对齐 go `z.MmapFile`）
2. VLog 写路径 mmap 化：`VLogManager` 追加写用 mmap（对齐 go value.go）
3. VLog 读路径 mmap 化（可选，vlog 读取也走映射）
4. `syncWrites=true` 语义保持：每次写后 `msync`（等价 fsync）
5. 崩溃一致性保持：WAL CRC + replay 语义不变

### 3.2 非目标

- SSTable 写入**不换 mmap**（go 也是普通 write；badger-cj 保留 io_uring 批量 + 同步降级）
- arena 内存分配不换 mmap（仓颉堆分配已够用，对齐收益小）
- 不引入运行中 remap（见 §5.3）

## 4. mmap-cj 能力评估

```cangjie
public common class MmapFile {
    public common init(path: String, size: Int64, readOnly!: Bool = false)
    public common func write(data: Array<Byte>, offset: Int64): Unit
    public common func read(offset: Int64, len: Int64): Array<Byte>
    public common func sync(): Unit      // msync / FlushViewOfFile
    public common func close(): Unit
    public common prop size: Int64
}
```

| 能力 | 满足度 | 说明 |
|------|--------|------|
| 固定大小映射 | ✅ | `init(path, size)`——vlog/WAL 预分配即可 |
| 偏移写/读 | ✅ | `write(data, offset)` / `read(offset, len)` |
| 同步 | ✅ | `sync()` = msync（syncWrites=true 每次写后调） |
| 三平台 | ✅ | linux/darwin/windows 已封装 |
| **Truncate/remap** | ❌ 无 | 用**预分配固定大小**规避（§5.3），无需扩展 mmap-cj |
| 文件扩展（稀疏） | 依赖平台 | 预分配后 `write` 越界写需映射覆盖——初始化时 `size` 取满额 |

**结论**：mmap-cj 现有 API 满足设计需求，**无需扩展**。

## 5. 设计

### 5.1 WAL 写（`WAL` 类改造）

现状（wal.cj）：`File + BufferedOutputStream(64KB)`，`write()` 写缓冲、`flush()`/`sync()` 落盘。

改造：

```cangjie
public class WAL {
    // open: 按预分配大小创建/打开映射
    //   size = memTableSize 上限（对齐 arena 2x memTableSize）
    private let mmap: MmapFile
    private var writeOffset: Int64 = 0   // 追加写游标（现有字段保留）

    public func write(key, valueEncoded): Unit {
        // 编码到字节后 mmap.write(encoded, writeOffset)；writeOffset += size
        // 越界保护：writeOffset + size > mmap.size → WAL 满（flush 前置条件，正常不触发）
    }
    public func flush(): Unit {}   // mmap 写即时可见，无缓冲 flush；语义 = 无操作
    public func sync(): Unit { mmap.sync() }
    public func close/delete: Unit {
        // 截断到实际写偏移（ftruncate），再删除/关闭——回收未写空间
    }
}
```

- `syncWrites=true`：`write()` 后立即 `mmap.sync()`（对齐现有 put 路径 memtable.cj:74）
- `syncWrites=false`：不 sync（页面写回由内核），**消除了 64KB 缓冲的"不满不落盘"不确定窗口**——mmap 页会按内核节奏写回，且 close/flush 时 msync 兜底

### 5.2 VLog 写（`VLogManager` 改造）

现状（vlog_manager.cj）：`File.write` 无缓冲（每次 syscall），写满 `maxFileSize` 开新段。

改造：

```cangjie
// 每段文件：
//   init: 创建 maxFileSize 稀疏文件 + MmapFile(path, maxFileSize)
//   append(entry): 编码 → mmap.write(encoded, writeOffset)；writeOffset += size
//   写满（writeOffset >= maxFileSize）: 截断当前段到 writeOffset → 开新段
//   sync(): mmap.sync()（syncWrites 路径）
//   读取（值指针解引用）: mmap.read(offset, len)（可选，读也走映射）
```

- 稀疏文件：预分配 1GB 不占实际磁盘（按写入量占用），mmap 映射虚拟空间
- 写满截断 + 开新段：段内固定映射，无 remap

### 5.3 预分配方案（规避 remap 段错误窗口）

go badger 在运行中 `Truncate + remap`（memtable.go:417 自述存在段错误窗口）。badger-cj **不采用运行中 remap**：

- **WAL**：每段 open 时预分配满额（memTableSize 数据上限），**段写满即换段**（`<fid>.mem` → `<fid>.mem.N`），
  段封口时截断回收——段内映射固定，仍无运行中 remap
  （换段原属阶段 4，因"单段固定容量必须自带兜底"已提前至阶段 1 实现）
- **VLog**：段内映射固定（maxFileSize），写满开新段

=> 全程无 remap，消除段错误窗口（比 go 更安全）。

### 5.4 崩溃一致性与恢复

| 场景 | 保证 |
|------|------|
| 进程崩溃（未 sync） | mmap 页面写回顺序不可控——与 go 同语义，靠 **WAL CRC + replay**（已实现，badger.cj open 恢复） |
| syncWrites=true | 每次写后 msync，崩溃不丢 |
| 段/文件截断异常 | 截断在 close/换段时执行；若崩溃在截断前，replay 按 CRC 容错 |

无需改恢复逻辑（WAL replay 按实际内容 CRC 校验，与写方式无关）。

### 5.5 与 io_uring 职责划分

| 路径 | v2.0 方案 |
|------|----------|
| WAL / VLog | **mmap**（本设计） |
| SSTable 批量写（close/compaction 多表） | 保留 io_uring（Linux 可选加速）+ 同步降级（v1.6.9） |
| SSTable 单表写 | writeFile（已有 io_uring→同步降级） |

io_uring 不再承担 WAL/vlog；v2.0 后 io_uring 仅作 Linux 下 SSTable 批量写的可选优化，**全平台路径默认不依赖 io_uring**。

## 6. 平台与测试策略

### 6.1 平台矩阵

| 平台 | WAL/VLog mmap | 测试 |
|------|---------------|------|
| Linux（x86_64/aarch64） | ✅ | GitHub Actions ubuntu + 本机 |
| macOS（arm64） | ✅ | **GitHub Actions macos-14（arm64）** |
| Windows | ✅（mmap-cj 已封装） | GitHub Actions windows（若可行） |

### 6.2 测试清单

1. **WAL 写入/重放**：现有 wal_test / large_batch_test（replay、事务原子性）全量跑通
2. **VLog 读写**：vlog_test / integration_test（值指针、GC）
3. **syncWrites 持久性**：transaction_atomicity_test.testSyncWritesDurability（崩溃模拟）
4. **分段**：小 maxFileSize 强制换段测试
5. **截断回收**：close 后文件实际大小 == 写偏移（无 1GB 空洞残留）
6. **优雅退出**：graceful_shutdown_test（close flush 落盘）
7. **三平台 CI**：macOS arm64 全量（本次新增能力）

## 7. 实施阶段与版本规划

### v2.0（mmap 适配，本设计）

| 阶段 | 内容 | 验收 |
|------|------|------|
| 1 | WAL mmap 化（WAL 类内部替换）+ **换段** | wal/large_batch/graceful_shutdown 测试过；换段用例过 |
| 2 | VLog 写 mmap 化 + 稀疏预分配 | vlog/integration/atomicity 测试过 |
| 3 | VLog 读 mmap 化（可选） | vlog 读取路径测试过 |
| 4 | 截断回收（换段已提前至阶段 1） | 文件大小断言 + 多段测试 |
| 5 | 三平台 CI 接入（macOS arm64） | GitHub Actions 全绿 |
| 6 | 性能复测（对比 v1.6.9） | DB Set 目标减半，更新 benchmark-report |

### 后续版本（v2.x，独立规划，不在 v2.0 内）

| 版本 | 内容 | 来源 |
|------|------|------|
| v2.1 | WAL batch write + group commit | benchmark P1 |
| v2.2 | Block/Index Cache | 需求文档 P1 |
| v2.3 | Merge Operator | 需求文档 P2 / 下一阶段 P2 |
| v2.4 | Managed DB（补全） | 下一阶段 P3（oracle isManaged 已预留） |
| v2.5 | Encryption | 下一阶段 P4 |

> 分布式特性不在路线（嵌入式库定位）；Backup/Restore、Stream API 已完成（v1.7）。

## 8. 风险与回退

| 风险 | 对策 |
|------|------|
| mmap 写性能不如预期 | 保留旧写路径开关（Config.MmapWAL/MmapVLog，默认开，可关回退） |
| 稀疏文件/截断的平台差异 | mmap-cj 封装层统一；Windows 实测优先 |
| 崩溃窗口变化 | 与 go 同语义（CRC + replay）；atomicity 测试覆盖 |
| mmap-cj 能力缺口 | 预分配方案规避 remap；若需扩展 mmap-cj（Truncate），单独发版 |

## 9. 相关文档

- `benchmark-report.md`（P1 优化项来源）
- `docs/plans/2026-03-11-iouring-optimization-design.md`（io_uring 设计，职责对照）
- `docs/progress-tracking.md`（路线图重构后）
- `docs/plans/2026-09-05-sstable-read-on-demand.md`（SSTable 读按需化——表数据移出
  GC 堆，与本文档共用 mmap-cj 基础设施，同属 v2.0）
- go 版：`~/Projects/badger/memtable.go`（z.MmapFile）、`value.go`（vlog mmap）
