# Badger-cj 项目进度跟踪

**最后更新：** 2026-09-02  
**当前阶段：** ✅ v1.6.13（v1.6.12 回归修复：memtable_iterator.cj 漏改 16 位掩码 → >64KB 值迭代读回截断；叠加 v1.6.12 flush 落盘语义对齐 badger-go + key/value 大小上限对齐）

---

## 项目状态

| 指标 | 状态 |
|------|------|
| **测试** | 336/336 通过 ✅ |
| **性能** | 事务写入 ~694-879K keys/s（优化后），Skiplist Get 1.12 us |
| **API 对齐** | P0+P1 完成，对齐率 ~85% |
| **版本** | 1.6.12（v1.6.12：flush 落盘对齐 badger-go + key/value 上限对齐；v1.6.10：写管道 Error 语义） |

---

## 路线图（Roadmap，统一计划表）

> 来源整合：progress「下一阶段功能」表 + benchmark-report 优化方向 + 需求文档 P0/P1/P2 + port-design v2.0 规划。
> 状态图例：✅ 已实现 / 🔶 设计中 / ⬜ 未开始 / ❌ 不做。

### v1.x（当前线）

| 计划项 | 来源 | 优先级 | 状态 |
|--------|------|--------|------|
| P0 MVP（KV/LSM/存储/事务） | 需求 P0 | — | ✅ |
| P1 功能（快照/迭代/压缩/GC/TTL） | 需求 P1 | — | ✅ |
| Backup/Restore / Stream API | port-design v2.0 | P1 | ✅ |
| io_uring（SSTable 批量写） | benchmark P3 | P3 | ✅（v1.6.9 起失败自动降级） |
| Snappy 压缩 | 下一阶段 | P2 | ✅（v1.3.0） |
| 优雅退出 / 关闭钩子 | 防复发 | — | ✅（v1.6.7/1.6.8） |

### v2.0（mmap 写路径，🔶 设计已落盘）

| 计划项 | 说明 | 优先级 | 状态 |
|--------|------|--------|------|
| **WAL mmap 化** | 对齐 go `z.MmapFile`，消除 64KB 缓冲落盘不确定 | P1 | 🔶 `docs/plans/2026-09-01-mmap-wal-vlog-design.md` |
| **VLog 写 mmap 化** | 对齐 go value.go，消除每次 syscall | P1 | 🔶 同上 |
| VLog 读 mmap 化 | vlog 读取走映射（可选） | P2 | ⬜ |
| 截断回收 / 换段边界 | 预分配稀疏文件 + close 截断 | P1 | 🔶 |
| 三平台 CI（macOS arm64） | GitHub Actions 全平台验证 | P1 | ⬜（设计已论证可行性） |

### v2.x（后续线，独立规划）

| 计划项 | 来源 | 优先级 | 状态 |
|--------|------|--------|------|
| WAL batch write + group commit | benchmark P1 | P1 | ⬜ |
| CloseableBlockingQueue 简化（remove 阻塞化 + 哨兵 close） | 调研（2026-09-01） | P2 | ⬜（官方文档确认 LinkedBlockingQueue 自带阻塞 remove()，当前手写 Condition 循环可去掉；多消费者 close 需哨兵唤醒） |
| Block/Index Cache | 需求 P1 性能优化 | P1 | ⬜ |
| ~~事务批量提交流水线~~ | benchmark P2 | P2 | ✅ 已实现（WritePipeline + flushLoop 批量收集，2026-07-17 channel 优化） |
| Merge Operator | 需求 P2 / 下一阶段 | P2 | ⬜ |
| Managed DB（补全） | 下一阶段 P3 | P3 | ⬜（仅 Oracle 底层支持 managed 时间戳模式，公开 API 未做） |
| Encryption | 下一阶段 P4 | P4 | ⬜ |
| Arena 内存池调优 | benchmark P2 | P2 | 🔶 部分（Arena 已实现，调优未做） |
| 分布式特性 | port-design v2.0 | — | ❌（嵌入式库定位） |

---

## 已完成阶段

### 反向迭代版本链修复 ✅ (2026-08-14)

**Bug 根因：** badger key 编码为 `[userKey][反转ts]`（invTs = MAX ^ ts 大端），同 userKey 多版本时**前向**迭代先遇新版本（正确），**反向**迭代先遇旧版本（错误）。`IteratorOptions(reverse: true)` 对「覆盖写 / 删除（tombstone）」的 key 会返回旧版本；clean 删除数据后 latest()/reverse 查询返回已删旧值（tsdb-cj 验证发现）。

| 任务 | 说明 |
|------|------|
| parseItem 反向分支 | 前缀过滤后、delete/dedup 前插入 `opt.reverse && !opt.allVersions` 分支 |
| collectReverseLatest | 消费当前 userKey 全部可见版本（物理连续），输出最新有效版本（ts 最大且未删除/未过期）；反向旧→新顺序，候选随遍历更新，**遇到删除/过期版本清空候选** |
| skipAdvance 标志 | collectReverseLatest 消费完链后 iitr 已定位到下一 key 首条目，`next()` 不能再 advance，否则跳过下一个 key（off-by-one） |
| keysEqual import | `import badgercj.utils.{hasPrefix, hashKey, keysEqual}` |
| allVersions 不修 | allVersions 调试模式保持原行为（返回所有版本） |

**测试验收（6 个新用例）：**
- `testReverseMultiVersion` - 覆盖写 key1: v1→v2，反向返回 v2（旧 bug 返回 v1）
- `testReverseMultiVersionMixedKeys` - 多 key 混合版本，无 key 被跳过（skipAdvance off-by-one 回归）
- `testReverseDeletedKey` - 删除(tombstone)后反向跳过该 key
- `testReverseDeleteThenRewrite` - 写→删→重写，反向返回重写的最新值
- `testReversePrefix` - reverse + prefix 组合，前缀内多版本取最新
- `testReverseAllVersionsUnchanged` - allVersions 反向保持原行为

**README 内存说明：** arena = 2 × memTableSize（默认 64MB → arena 128MB/库）；仓颉 GC 堆默认上限 256MB（cjHeapSize/cjGCThreshold/cjGCInterval/cjBackupGCInterval 可调）；嵌入式/低内存/多库建议调小 memTableSize。

**发版：** badgercj 1.6.5（已发布，含 snappy 1.0.1 升级但无本修复）→ 中心仓不允许覆盖 → 本修复发布为 **v1.6.6**；tsdb-cj 随后升级 badgercj 依赖到 1.6.6。

### PrefixIterable 功能 ✅ (2026-04-02)

| 任务 | 说明 |
|------|------|
| PrefixIterable 类 | 实现 `StdIterable<Item>` 接口，支持 for-in |
| PrefixIterator 类 | 实现 `StdIterator<Item>` 接口，`next()` 返回 `Option<Item>` |
| Badger.scan() 方法 | 返回 `PrefixIterable`，支持前缀范围迭代 |
| Item 属性修复 | `key`/`value`/`version` 是属性，不是方法 |

**关键发现：**
- 仓颉 `StdIterable<T>` 需要 `iterator()` 返回 `StdIterator<T>`
- 仓颉 `StdIterator<T>` 的 `next()` 返回 `Option<T>`，不需要 `mut` 修饰符
- Item 类的 `key`, `value`, `version` 是 `public let` 属性，访问用 `.key` 而不是 `.key()`

**使用示例：**
```cangjie
let iterable = db.scan(Array<Byte>(prefix, repeat: 0))
for (item in iterable) {
    println("key: ${item.key}, value: ${item.value}")
}
```

### 事务原子性修复 ✅ (2026-04-01)

| 任务 | 说明 |
|------|------|
| bitTxn/bitFinTxn 标记 | 事务条目标记 0x40，结束标记 0x80 |
| TxnKey 常量 | "!badger!txn" 用于事务结束条目 |
| ValueStruct 方法 | isTxnEntry/isFinTxn/withTxnMark/clearTxnMarks |
| 事务提交流程 | 所有条目添加 bitTxn，最后追加 bitFinTxn |
| WAL replay | 事务边界处理，未完成事务自动丢弃 |
| SyncWrites 配置 | 每次写入后 fsync，严格持久性 |
| 迭代器修复 | 跳过 bitFinTxn 条目 |

**测试验收：**
- `testTransactionMarkerWritten` - 验证事务标记写入
- `testIncompleteTransactionDiscarded` - 未完成事务丢弃
- `testCompleteTransactionRecovered` - 完整事务恢复
- `testSyncWritesDurability` - SyncWrites 持久性
- `testMultipleTransactionsRecovery` - 多事务恢复

**ACID 特性：**
- 原子性：bitTxn/bitFinTxn 标记 + WAL replay 边界处理
- 一致性：MVCC + SSI 冲突检测
- 隔离性：Snapshot Isolation
- 持久性：WAL + SyncWrites 选项

### 迭代器架构重构 ✅ (2026-03-26)

| 任务 | 说明 |
|------|------|
| TableIterWrapper | 新增支持反向迭代的包装器，传递 reverse 参数 |
| 删除旧 TableIteratorWrapper | 移除不支持 reverse 的旧包装器 |
| LevelHandler.appendIterators | 传递完整 IteratorOptions 对象 |
| compaction.cj 简化 | 直接使用 TableInterface.newIterator() |

**关键修复：**
- `TableIterWrapper` 添加 `reverse` 参数，支持反向迭代
- `LevelHandler.appendIterators` 参数类型从 `Bool` 改为 `IteratorOptions`
- 删除冗余的 `TableInterfaceIterator` 引用，简化 compaction 代码

### P1: Backup/Restore ✅ (2026-03-21)

| 功能 | 说明 |
|------|------|
| BackupWriter | 写入备份数据流，支持 KVList 分块 |
| BackupReader | 读取备份数据流，恢复到新 DB |
| Badger.Backup() | 全量/增量备份，返回 maxVersion |
| Badger.Restore() | 从备份文件恢复数据 |
| TTL 支持 | expiresAt 正确保留和恢复 |

**文件格式：**
```
Header (12 bytes): Magic("BADCJ") + Version(UInt32) + Flags(UInt32)
KVList Block (repeated): Size(UInt64) + Count(UInt32) + MaxVersion(UInt64) + KV entries
KV Entry: KeyLen + Key + ValueLen + Value + UserMeta + Version + ExpiresAt + Meta
```

**测试用例：**
- testBackupRestore: 基本备份恢复
- testBackupWithTTL: TTL 数据备份恢复
- testIncrementalBackup: 增量备份（since 参数）
- testBackupEmptyDB: 空数据库备份
- testBackupWithUserMeta: 用户元数据保留

**关键修复：**
- `setRaw()` 方法添加 `expiresAt` 参数，确保 TTL 数据正确恢复
- VLogGCDB 接口同步更新，GC 流程也传递 expiresAt

### P1: Stream API ✅ (2026-03-21)

| 功能 | 说明 |
|------|------|
| StreamKV struct | 流式 KV 数据结构 |
| Stream class | 并发迭代框架，支持 prefix/numGo/sinceTs/chooseKey/keyToList/send |
| KeyRange class | key 范围 [left, right) |
| Badger.ranges() | 生成 key 范围分割，用于并发迭代 |
| MergeIterator 去重修复 | 修复了重复 key 问题 |

**关键发现：**
- MergeIterator 需要在 `fix()` 中处理相同 key 的情况（推进其中一个迭代器）
- `ranges()` 方法需要使用用户 key（去掉时间戳）作为分割点
- `allVersions = true` 时迭代器返回所有版本，需要 `defaultToList` 正确处理

**测试用例：**
- testBasicStream: 基本流式迭代
- testStreamWithPrefix: 前缀过滤
- testStreamCollectAll: 收集所有 KV

### P1: 代码重构 ✅ (2026-03-21)

提取重复代码到 `src/utils/` 公共包：

| 文件 | 函数 | 来源 |
|------|------|------|
| `utils/key_utils.cj` | compareKeys, keysEqual, hasPrefix, hashKey | 12+ 处重复删除 |
| `utils/byte_utils.cj` | u32ToLE, u32FromLE, u64ToLE, u64FromLE | encoding/crc32.cj |

**重构效果：**
- 删除 `table/table_index.cj` 中 3 个私有函数 (readUInt32/readUInt64/readBytes)
- 统一使用 utils 公共函数
- 代码更简洁，维护更方便

### P0: io_uring 批量优化 ✅ (2026-03-21)

| 功能 | 说明 |
|------|------|
| IoUringPool 全局实例池 | 单例模式，复用 io_uring 实例 |
| writeFilesBatch() 批量接口 | 一次提交多个写请求 |
| flushMemTablesBatch() | close() 时批量写入多个 imm MemTable |
| 移除每次 write() 的 submit() | 延迟到 sync()/close() 批量提交 |

**性能测试结果：**

| 场景 | Sync | io_uring | Speedup |
|------|------|----------|---------|
| 小 MemTable 频繁 flush | 152ms | 148ms | **1.2x** |
| 大 MemTable (64MB) | 2238ms | 2102ms | **1.6x** |
| 高并发多 imm MemTable | 315ms | 288ms | **1.9x** |

**默认开启：** `Config.UseIoUring = true`

### P0: io_uring 集成 ✅ (2026-03-20)

| 功能 | 说明 |
|------|------|
| Config.UseIoUring | 配置开关，默认 true |
| writeFile() 工具函数 | 自动选择 io_uring/同步写入 |
| SSTable 写入 | flushMemTableToDisk + compaction |
| 测试 | 262 测试通过 |

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

## 性能

| 操作 | Go Badger | badger-cj | 比率 |
|------|-----------|-----------|------|
| 直接写入 | ~1.5M keys/s | 616K keys/s | 2.4x |
| 事务写入 (50并发) | ~1.0M keys/s | 400K keys/s | 2.5x |
| DB Get | ~1 µs | 2.9 µs | 2.9x |
| DB Set | ~5 µs | 7.4 µs | 1.5x |

> io_uring 已完成，实测性能提升 10-60%

---

## 技术决策记录

| 问题 | 解决方案 |
|------|---------|
| Backup/Restore TTL 丢失 | setRaw() 添加 expiresAt 参数，VLogGCDB 接口同步更新 |
| Stream API ranges 分割 | 使用用户 key（去掉时间戳）作为分割点 |
| MergeIterator 重复 key | fix() 中处理相同 key，推进其中一个迭代器 |
| allVersions 模式去重 | Iterator.parseItem() 根据 allVersions 决定是否跳过相同 key |
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
| 2026-09-02 | v1.6.13 | 修复 v1.6.12 回归：value 槽 UInt16→UInt32 升级漏改 `memtable_iterator.cj`（seek 与 LazySkipIterator 两处 `& 0xFFFF` 掩码仍 16 位）——>64KB 内联值经事务迭代器（Iterator→MergeIterator→MemTableIterator）读回被截断（80141→14605），忆时塔 materialize 报 "array length 14605, range [6, 80141)" 数组越界；新增回归测试 `KeyValueLimitTest.testValue100KBReadBackViaMemtableIterator`（迭代 + seek 双路径完整找回 100KB 值）；346 测试通过 |
| 2026-09-02 | v1.6.12 | key/value 大小语义对齐 badger-go：① key > 65000 写入前拒绝（事务/批量路径，`prepareEntries` 在 vlog/WAL 之前校验；此前无检查——大 key 写"成功"、flush 建表时 UInt16 窄化抛系统级异常炸写路径）；② value 取消 64KB 编码限制（memtable node value 槽 UInt16→UInt32 + 3 处掩码，同 keySize 修复手法）——[64KB, ValueThreshold) 值从断写报错恢复为内联成功；③ value > vlog 单文件容量(1<<30-1) 拒绝（go ValueLogFileSize 同款）；④ block_builder UInt16 段长窄化防御。新增 key_value_limit_test 4 用例；large_batch_test 3 用例按新语义改写；
| 2026-09-02 | v1.6.11 | flush 落盘语义对齐 badger-go（issue: flush-no-persist-oom-mcp-hang）：① 运行期 `flushToLevel` 恢复落盘原语——写 L0 SSTable（io_uring 降级）+ MANIFEST 先记录 + 从 imm 出队释放 + decrRef 删 WAL，事务标记处理与 close 路径统一；open 恢复遗留 imm 立即 flush（对齐 go db.go:353 "Flush them to disk asap"）；② 修 open memtable fid 未走 reserve 导致的 id 撞车（flush 误删新表 WAL 的崩溃丢数据窗口，`seedFileIDAfter`）；③ 修磁盘表 seek 定位（R3）：`findBlock` 对 seek 版本 ≥ 组内最大存储版本且组首恰为块首的 key 错误回退前一块 → 重启后旧表 key 稳定 miss（实测 45/160）；`TableAdapter.get` 改走跨块 TableIterator；④ 去 `loadTables` 双载（LevelsController.init 与 open 各一次，reopen 每表双份）；⑤ close 批量/compaction 写盘结果检查 + compactor 异常防护不杀协程 + close 落盘后 decrRef 清 WAL 防 reopen 重复；⑥ compaction 表 id 改 `reserveFileID`（原误用 `db.getVersion()`）。新增 `flush_persist_regression_test.cj`（运行期落盘/双配置 close→reopen 160/160/不 close 崩溃重开 160/160）；
| 2026-09-01 | v2.0 规划 | 路线图重构（统一进度表：v1.x 已完成线 / v2.0 mmap 线 / v2.x 后续线）+ mmap 写路径设计落盘 `plans/2026-09-01-mmap-wal-vlog-design.md`（WAL/VLog mmap 化对齐 go z.MmapFile，预分配规避 remap 段错误窗口，io_uring 仅留 SSTable 可选加速）；benchmark/需求文档状态同步 |
| 2026-08-31 | v1.6.9 | io_uring 降级同步写：`writeFilesBatch` 在 io_uring 初始化/使用失败时自动降级 `syncWriteFilesFallback`（首败置全局标志防反复重试）——Docker builtin seccomp 默认拦截 io_uring_setup（Go 程序三向对照实测：宿主/内核可用、seccomp=unconfined 可用、默认 seccomp EPERM），容器内 close 多表批量 flush 必挂（优雅退出失败）；1 测试（降级标志后 useIoUring:true 同步写成功），336 测试通过 |
| 2026-08-31 | v1.6.8 | 优雅关闭钩子 `registerShutdownHook(cb)`：宿主与 badger 共存监听信号两种模式——模式 A（宿主先注册 handler 返回 false，再调 registerSignalShutdown）与模式 B（钩子注册进 badger，信号时后台线程 close 前按序执行）；实测确认 handler 返回 false 会触发信号默认终止（进程被 SIGTERM 杀死、close 来不及执行），badger 必须返回 true；2 测试（钩子执行/顺序），335 测试通过 |
| 2026-08-31 | v1.6.7 | write-fail-loud 完善 + 优雅退出：vlog.write 移出全局写锁（prepare→锁内 put 两阶段）、drain 路径错误传播（writeOneRequest markFailed + 合并重复逻辑）、WAL replay 整事务原子恢复（坏条目→整事务丢弃）、`registerSignalShutdown()`（std.runtime SIGINT/SIGTERM → close + exit，`@When[os == "Linux"]` 条件编译，非 Linux no-op）、README Docker 段更新；332 测试通过 |
| 2026-08-31 | v1.6.7 | 优雅退出端到端验证：`src/examples/graceful_exit`（write/write-nosignal/read 模式，`--static` 编译）与 `scripts/graceful_shutdown_e2e.sh`（写 5000 条不落盘 → SIGTERM → exit(0)+落盘 → 重启 5000/5000 稳定通过；对照组无优雅退出 → 143 → 0/5000 全丢） |
| 2026-08-23 | v1.6.7 | 文档：README「进程退出时自动关闭」补 Docker 说明——atExit/AutoCloseOnExit 不处理 docker SIGTERM（docker stop/restart 直接终止进程不跑退出回调，已实测），容器环境建议 `Config.withSyncWrites(true)` 同步落盘保证持久性 |
| 2026-07-17 | v1.6.2 | 性能优化：CloseableBlockingQueue (LinkedBlockingQueue+Condition)、WAL BufferedOutputStream、keyWithTs 消除临时分配、MemTable 避免重复编码、事务吞吐提升 69-106%、Skiplist Get 提升 50%、323 测试通过 |
| 2026-03-26 | v7.14 | 迭代器架构重构：TableIterWrapper 支持 reverse、删除旧 TableIteratorWrapper、LevelHandler 参数修复、293 测试通过 |
| 2026-03-21 | v7.13 | P1 Backup/Restore 完成：全量/增量备份、TTL/UserMeta 支持、setRaw() 添加 expiresAt 参数、270 测试通过 |
| 2026-03-21 | v7.12 | P1 代码重构：提取 utils/key_utils.cj 和 utils/byte_utils.cj，删除 15+ 处重复代码 |
| 2026-03-21 | v7.11 | P1 Stream API 完成：StreamKV/Stream/KeyRange/ranges()、MergeIterator 去重修复、265 测试通过 |
| 2026-03-21 | v7.10 | P0 io_uring 批量优化完成：IoUringPool、writeFilesBatch()、flushMemTablesBatch()、10-60% 性能提升；确认 WriteBatch 已实现 |
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