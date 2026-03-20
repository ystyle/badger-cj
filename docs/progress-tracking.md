# Badger-cj 项目进度跟踪

**最后更新：** 2026-03-20  
**当前阶段：** ✅ P0 io_uring 集成完成

---

## 项目状态

| 指标 | 状态 |
|------|------|
| **测试** | 262/262 通过 ✅ |
| **性能** | 直接写入 ~616K keys/s，事务写入 ~400-441K keys/s |
| **API 对齐** | P0+P1 完成，对齐率 ~80% |

---

## 已完成阶段

### P0: io_uring 集成 ✅ (2026-03-20)

| 功能 | 说明 |
|------|------|
| Config.UseIoUring | 配置开关，默认 true |
| writeFile() 工具函数 | 自动选择 io_uring/同步写入 |
| SSTable 写入 | flushMemTableToDisk + compaction |
| 测试 | 5 个新测试，总计 262 通过 |

**集成分析：**
- SSTable: ✅ 批量大写入，适合 io_uring
- VLog: 暂不需要（当前内存实现，无持久化）
- WAL: 不适合（增量小写入，事务安全优先）
- Manifest: 不适合（增量小写入，元数据安全优先）

### P0: io_uring FFI 绑定 ✅ (2026-03-20)

| 功能 | 说明 |
|------|------|
| FFI 绑定 | SQE/CQE 结构 + liburing 函数 |
| 条件编译 | `@When[os == "Linux"]` 跨平台支持 |
| cjpm.toml | `[target.x86_64-unknown-linux-gnu]` 平台链接 |
| IoUringFileWriter | 异步文件写入器（缓冲区管理） |
| 测试 | 5 个测试通过 |

**关键发现：**
- liburing inline 函数无法 FFI 调用，需手动实现
- `LibC.malloc<Unit>` 导致除零错误
- 异步写入需要缓冲区管理，I/O 完成前保持数据有效

### P0: BloomFilter ✅ (2026-03-20)

| 功能 | 说明 |
|------|------|
| BloomFilter 类 | 兼容 Go BadgerDB 格式 |
| TableBuilder 集成 | 构建时生成 filter |
| Table 读取优化 | mayContain() 快速过滤 |
| Config.BloomFalsePositive | 默认 0.01 (1% 误判率) |

### P1: API 扩展 ✅ (2026-03-15)

| 功能 | 说明 |
|------|------|
| Config with* | 7 个链式配置方法 |
| DB.isClosed/sync/size/tables/levels | 数据库信息查询 |
| Iterator.validForPrefix | 前缀匹配迭代 |

### P0: API 对齐 ✅ (2026-03-15)

| 功能 | 说明 |
|------|------|
| BadgerException | 异常类 + ErrorCode |
| Entry withTTL/withMeta/withDiscard | TTL 过期 + 用户元数据 |
| Item 完整 API | keyCopy/valueCopy/size 等 |
| IteratorOptions | 完整字段 |

### Phase 7: Compaction + VLog GC ✅ (2026-03-14)

- 完整多层级 Compaction (L0→L1→...→L6)
- VLog GC 后台自动回收

### Phase 6: 性能优化 ✅ (2026-03-12)

- 无锁并发 SkipList
- 各种写入路径优化
- 独立基准测试程序

### Phase 5: 持久化 ✅ (2026-03-11)

- DB.close() flush 到 SSTable
- DB.open() 恢复

### Phase 4: 事务系统 ✅ (2026-03-09)

- Oracle/WaterMark/SSI/Iterator/Snapshot/MVCC

### Phase 3: 核心功能 ✅ (2026-03-08)

- MemTable/WAL/LevelsController/DB

### Phase 2: 存储引擎 ✅ (2026-03-08)

- SSTable/VLog/MANIFEST

### Phase 1: 基础设施 ✅ (2025-03-08)

- CRC32/Varint/Arena/Skiplist

---

## 当前任务：io_uring 性能优化

### 已完成

| 任务 | 说明 | 状态 |
|------|------|------|
| Config.UseIoUring | 配置开关，默认 false | ✅ 完成 |
| writeFile() 工具函数 | 自动选择 io_uring/同步写入 | ✅ 完成 |
| SSTable 写入集成 | flushMemTableToDisk + compaction | ✅ 完成 |
| IoUringPool 全局实例池 | 单例模式，复用 io_uring | ✅ 完成 |
| writeFilesBatch() 批量写入 | 一次提交多个写请求 | ✅ 完成 |
| 性能基准测试 | 对比同步 vs io_uring | ✅ 完成 |

### 性能测试结论

**当前场景：io_uring 不如同步写入**

| 场景 | 同步 | io_uring Batch | 原因 |
|------|------|----------------|------|
| 4 文件并发 | 5ms | 14ms | 数据在内存，同步写入立即返回 |
| 16 文件并发 | 20ms | 46ms | 页缓存延迟写入，无物理 I/O |

**io_uring 需要更深层次优化：**
- O_DIRECT 绕过页缓存
- SQPOLL 内核轮询模式
- 链式请求并行执行

### 后续优化方向

| 优化项 | 预期收益 | 复杂度 |
|--------|---------|--------|
| O_DIRECT 直接 I/O | 真实磁盘写入加速 | 高 |
| SQPOLL 模式 | 减少系统调用 | 中 |
| 异步流式写入 | 不阻塞业务线程 | 高 |

**当前建议：保持 UseIoUring = false，等待后续深度优化**

### 集成设计要点

```
┌─────────────────────────────────────────────────────────────┐
│  写入路径                                                   │
│    ↓                                                        │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │ TableBuilder │    │    VLog     │    │     WAL     │     │
│  │   (SSTable)  │    │  (大值存储)  │    │  (事务日志)  │     │
│  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘     │
│         │                  │                  │             │
│         └──────────────────┼──────────────────┘             │
│                            ↓                                │
│              createIoUringWriter(path)                      │
│                            │                                │
│              ┌─────────────┴─────────────┐                  │
│              ↓                           ↓                  │
│      Linux + 可用                   其他情况                 │
│      IoUringFileWriter            普通文件写入               │
│      (异步批量写入)               (同步写入)                  │
└─────────────────────────────────────────────────────────────┘
```

---

## 已实现功能

### 核心功能 ✅
- KV 存储 (Get/Set/Delete)
- MemTable (基于 Skiplist)
- WAL (Write-Ahead Log)
- SSTable (带前缀压缩 + BloomFilter)
- Value Log (大值分离存储)
- MANIFEST (元数据管理)
- Compaction (完整多层级)
- VLog GC (后台自动回收)
- BloomFilter (读取优化)

### 事务系统 ✅
- Oracle 全局时间戳管理
- WaterMark 完成追踪
- SSI 可串行化快照隔离
- 冲突检测
- Read-your-writes 语义

### 迭代器 ✅
- 前向/反向迭代
- Seek 定位
- 前缀过滤
- validForPrefix

### API 增强 ✅
- TTL 过期 + 自动清理
- 用户元数据 (userMeta)
- 链式配置 (with*)
- 数据库信息查询

### 并发与持久化 ✅
- 无锁并发 SkipList (真 CAS)
- DB.close() flush
- DB.open() 恢复
- 崩溃恢复

### io_uring ✅
- FFI 绑定 (条件编译)
- 异步文件写入器
- 缓冲区管理
- 跨平台接口
- SSTable 写入集成
- Config.UseIoUring 配置

---

## 性能

| 操作 | Go Badger | badger-cj | 比率 |
|------|-----------|-----------|------|
| 直接写入 | ~1.5M keys/s | 616K keys/s | 2.4x |
| 事务写入 (50并发) | ~1.0M keys/s | 400K keys/s | 2.5x |
| DB Get | ~1 µs | 2.9 µs | 2.9x |
| DB Set | ~5 µs | 7.4 µs | 1.5x |

> io_uring 集成后预期性能提升 20-50%

---

## 待实现功能

| 功能 | 优先级 | 说明 |
|------|--------|------|
| io_uring 集成 | P0 | 集成到写入路径 |
| WriteBatch | P1 | 批量写入优化 |
| Backup/Restore | P2 | 数据备份恢复 |
| Stream API | P2 | 大规模数据处理 |
| Managed DB | P2 | 手动管理时间戳 |
| Compression | P2 | SSTable 压缩（需 Snappy 库） |
| Merge Operator | P4 | 原子更新操作 |
| Encryption | P4 | 加密存储 |

---

## 技术决策记录

| 问题 | 解决方案 |
|------|---------|
| 仓颉无 unsafe.Pointer | UInt32 offset 索引 Arena |
| 仓颉无 FlatBuffers | 手动实现兼容编码 |
| SkipList 伪 CAS 不安全 | AtomicStorage 真正 CAS |
| VLog GC 循环依赖 | VLogGCDB 接口解耦 |
| Entry.meta vs userMeta | 分离内部标记和用户标记 |
| liburing inline 函数 | 定义 C 结构 + 手动实现 |
| io_uring 异步内存 | 缓冲区管理 + pending 跟踪 |
| 跨平台 FFI | @When 条件编译 + 接口抽象 |

> 详细技术决策、仓颉语言陷阱、优化经验见 [cangjie-lessons-learned.md](./cangjie-lessons-learned.md)

---

## 文档索引

- `README.md` - 使用指南
- `docs/api-alignment-report.md` - API 对齐详情
- `docs/benchmark-report.md` - 性能测试
- `docs/plans/` - 设计文档
- `docs/badger-analysis/` - 算法分析
- `docs/plans/2026-03-11-iouring-optimization-design.md` - io_uring 设计

---

## 更新历史

| 日期 | 版本 | 变更 |
|------|------|------|
| 2026-03-20 | v7.9 | P0 io_uring 集成完成：SSTable 写入、Config.UseIoUring、writeFile() 工具函数、262 测试通过 |
| 2026-03-20 | v7.8 | P0 io_uring FFI 绑定完成：条件编译、异步写入器、257 测试通过 |
| 2026-03-20 | v7.7 | P0 BloomFilter 完成：TableBuilder/Table 集成，默认 1% 误判率 |
| 2026-03-15 | v7.6 | P1 完成：Config with*/DB info/validForPrefix |
| 2026-03-15 | v7.5 | P0 完成：TTL/异常/Item API |
| 2026-03-14 | v7.4 | Phase 7 完成：Compaction + VLog GC |
| 2026-03-12 | v7.3 | Phase 6 完成：性能优化 |
| 2026-03-11 | v7.2 | Phase 5 完成：持久化 |
| 2026-03-09 | v7.1 | Phase 4 完成：事务系统 |
| 2026-03-08 | v7.0 | Phase 2-3 完成：存储引擎 + 核心功能 |
| 2025-03-08 | v1.0 | Phase 1 完成：基础设施 |