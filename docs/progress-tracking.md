# Badger-cj 项目进度跟踪

**最后更新：** 2026-10-06  
**当前阶段：** ✅ v1.6.16（reverse seek 编码对齐 badger-go（seek 存在 key 不再漏组）+ WritePipeline OOM 批显式失败；叠加 v1.6.15 跨 block 间隙修复、v1.6.14 reverse seek/迭代修复、v1.6.13 memtable_iterator 掩码修复、v1.6.12 flush 落盘语义对齐）

---

## 项目状态

| 指标 | 状态 |
|------|------|
| **测试** | 388/388 通过 ✅ |
| **性能** | 事务写入 ~694-879K keys/s（优化后），Skiplist Get 1.12 us |
| **API 对齐** | P0+P1 完成，对齐率 ~85% |
| **版本** | 1.6.16（v1.6.16：reverse seek 编码对齐 + WritePipeline Error 整批失败；v1.6.15：磁盘表正向 seek 跨 block 间隙修复；v1.6.14：reverse seek/迭代修复；v1.6.13：memtable_iterator 掩码修复；v1.6.12：flush 落盘对齐 badger-go + key/value 上限对齐；v1.6.10：写管道 Error 语义） |

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
| flush 异步化（移出写锁 + 背压） | #518 评审 P2-2 | P2 | ✅（e744941，v1.6.17） |
| TableBuilder 单拷贝（L1） | 内存峰值优化 | P2 | ✅（3c8f261，v1.6.17） |

### v2.0（mmap 写路径，🔶 设计已落盘）

| 计划项 | 说明 | 优先级 | 状态 |
|--------|------|--------|------|
| **WAL mmap 化** | 对齐 go `z.MmapFile`，消除 64KB 缓冲落盘不确定 | P1 | 🔶 `docs/plans/2026-09-01-mmap-wal-vlog-design.md` |
| **VLog 写 mmap 化** | 对齐 go value.go，消除每次 syscall | P1 | 🔶 同上 |
| VLog 读 mmap 化 | vlog 读取走映射（可选） | P2 | ⬜ |
| 截断回收 / 换段边界 | 预分配稀疏文件 + close 截断 | P1 | 🔶 |
| 三平台 CI（macOS arm64） | GitHub Actions 全平台验证 | P1 | ⬜（设计已论证可行性） |
| **SSTable 读按需化**（表数据移出 GC 堆） | chronomem OOM 结构矛盾（2026-09-05） | P1 | 🔶 实施中：阶段 A（TableData 抽象）✅、阶段 B（MmapTableData 接入 flush/compaction/恢复）✅ 已完成；C（生命周期收口）✅ 已完成；D（性能对照）待做 `docs/plans/2026-09-05-sstable-read-on-demand.md`（mmap 读，与 WAL/VLog mmap 同栈） |

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
| 2026-10-06 | feat/v2-mmap-wal-vlog（未发版，分支） | **v2.0：SSTable 读按需化 阶段 C（生命周期收口）**：`TableInterface` 增加 `close()`（`TableAdapter` 转发到 `Table.close()` 释放映射、`MockTable` 空实现），补两处释放点：① **compaction 摘表即 close**（`deleteTables` 中被替换的表；依据「读块是复制语义 → 摘除时无并发读者持有表数据 → 无需引用计数」的免 refcount 方案）；② **`Badger.close()` 释放全部表**（`LevelsController.closeTables()`），避免进程内反复 open/close 累积虚拟地址。全量 **388/388 通过**。**Windows 约定**：被映射文件不能删除，将来实现表文件 unlink 时必须**先 close 再 unlink**（已写入接口注释）。**另记一个不在本次范围的既有缺口**：生产代码**没有删除 compaction 后的 `.sst` 文件**，磁盘占用会随 compaction 持续增长，需单独处理 |
| 2026-10-06 | feat/v2-mmap-wal-vlog（未发版，分支） | **v2.0：SSTable 读按需化 阶段 B 接入完成——表数据正式移出 GC 堆**：新增 `Config.MmapSSTable`（默认开），三条路径全部接入 `MmapTableData`：① **恢复** `loadTables` 不再 `File.readFrom` 全量读盘，改为只读映射 + 按需解析尾部索引；② **flush** 落盘后建表改映射（构建产物 `data` 至此可弃，峰值内存再降一档）；③ **compaction** 产出新表同样改映射。关闭开关则退回整表读入（v1.x 路径）。全量 **388/388 通过**（默认映射路径由全部用例覆盖，另补 SSTable 映射关闭的回退用例）。**至此设计 §1.1 的根因被消除**：稳态堆 = 元数据 + memtable，与数据总量解耦，OOM 退化为页缓存性能波动。**待做**：阶段 C 生命周期收口（摘表 close / Windows 先 close 后 unlink）、阶段 D 性能与内存对照 |
| 2026-10-06 | feat/v2-mmap-wal-vlog（未发版，分支） | **v2.0：SSTable 读按需化 阶段 B 基础设施**：新增 `MmapTableData`（`mmap-cj` 只读映射，**unlink 后映射仍有效**）；`TableIndex.decodeFromTableData` **只读文件尾部三段**（末尾 4B 的 crc 长度 → 其前 `indexSize` → index 本体）解析索引，**不把整表读进内存**——这是「表数据移出 GC 堆」的关键；`Table` 新增以 `TableData` 构造（命名参数 `tableData!`，与既有 `Array<Byte>` 构造消歧）与 `close()`（释放映射）。新增用例：**双模式等价**（同一 .sst 经 `MemoryTableData` 与 `MmapTableData` 打开：元信息 + 逐 key 内容 + 块迭代器一致）、**按需读索引**。全量 **387/387 通过**。**待做**：flush/compaction/loadTables 接入 `MmapTableData`——届时表数据才真正离开 GC 堆 |
| 2026-10-06 | feat/v2-mmap-wal-vlog（未发版，分支） | **v2.0：SSTable 读按需化 阶段 A（`TableData` 抽象，纯重构）**：新增 `TableData` 接口（`read(offset,len)` 复制语义 / `size()` / `close()`）与 `MemoryTableData`；`Table` 的 `data: Array<Byte>` 改为持有 `TableData`，`readBlock` / `onDiskSize` / `uncompressedSize` 三处随之切换——**行为零变化**，全量 385/385 通过。接口刻意按「**读块即复制**」设计：调用方读块后不再持有表数据，使后续「表从 LevelHandler 摘除后即可释放底层资源」**无需引用计数**（阶段 C 生命周期收口的前提）。后续阶段：B 接入 `MmapTableData`（flush/compaction/loadTables 走只读映射 + `TableIndex` 改为按需读文件尾部）、C 生命周期审计（Windows 先 close 后 unlink）、D 性能与内存对照（chronomem 堆曲线） |
| 2026-10-06 | feat/v2-mmap-wal-vlog（未发版，分支） | **v2.0 阶段 4 收口断言 + `Config.MmapVLog` 开关**：新增 `Config.MmapVLog`（默认开，对称于 `MmapWAL`），关闭时 `VLogFile` 回退无缓冲 `File.write`（v1.x 路径）。阶段 4 的验收**不能只断言"关闭后文件小"**——若预分配从未发生，测试会空过；因此新用例先断言**打开期间 WAL/VLog 段确实被预分配到容量上限**，再断言关闭后缩回有效长度，并校验重开数据完好（证明截断回收没截掉有效数据）。新增：`testPreallocThenReclaimOnClose`、`MmapSwitchTest`（两开关同关仍可往返 / mmap 开启下多轮大值写入读回）、`testVLogNonMmapFallback`（未预分配）。**注意**：单测 `memTableSize` 必须按项目约定取小值（64KB）——最初写 8MB，`-j 16` 并发下 `Arena::init` 直接 OOM。全量 **385/385 通过** |
| 2026-10-06 | feat/v2-mmap-wal-vlog（未发版，分支） | **v2.0 阶段 2：VLog 写路径 mmap 化（稀疏预分配 + 段内固定映射）**：`VLogFile` 增加 `useMmap` 路径——段按 `maxFileSize` 稀疏预分配后建立固定映射，`write` 走 memcpy、`sync` 走 `msync`；逻辑大小 `size()` 与物理文件长度**解耦**（预分配后后者恒为 maxFileSize），段写满换段、单条放不下时换段重试并按需放大新段（与 WAL 容量兜底同一策略）。**过程中修掉一个高危既有缺陷**：`VLogManager` 重开时完全不恢复状态（`maxFid=0` / `offset=0` / `files` 只注册 fid 0）→ 重开后写入的 `ValuePointer.offset` 从 0 开始，**读到别的旧 value（静默数据损坏）**；且换段会覆盖已有段、旧段 value 读不到。现改为扫描目录重建段表、逐段恢复有效写偏移。另有两处实现要点：① 恢复扫描**必须流式**（段预分配是 GB 级，整体读入直接 OOM）；② 条目固定开销是 **13** 字节（`keyLen(4)+valueLen(4)+key+value+meta(1)+crc(4)`），误用「最小可解码头部 9」会把有效长度算成 0。新增 3 个用例（预分配 / 重开保持数据与偏移 / 按 maxFileSize 换段读回）；全量 **381/381 通过** |
| 2026-10-06 | feat/v2-mmap-wal-vlog（未发版，分支） | **修复写管道「同一请求 done 两次」竞态（偶发写入失败）**：`writeRequests` 与 `runBatch` 的 finally 各对每个请求调用一次 `done()`，`SyncCounter` 被多减一次 → `waitUntilZero()` **提前唤醒** → 调用方把请求归还对象池，另一线程取出后 `reset()` 清空 entries，而 `runBatch` 的 finally 仍在遍历同一请求 → **`ConcurrentModificationException`**（`writeRequests` 自身的注释已写明 done 由 runBatch 统一负责，实为重复调用）。影响**所有写入路径**（`batchSet` / `batchSetAsync` / 事务提交），表现为偶发写入失败。修复：删除 `writeRequests` 中多余的 done 循环。新增回归用例 `testBatchSetNoDoubleDoneRace`（单线程高频批量写 4000×32）；该竞态在单元测试规模下**不稳定复现**，故另用新示例压测验证：修复前 400k keys 单线程可复现 `failed≥1`，修复后连续 18 次 rep **全部 failed=0**。**顺带产出**：新增 `batch_commit_perf` 示例对比 `batchSet` 与 `batchSetAsync` —— 8 线程 async 慢 9.2%（t=−0.73）、1 线程 async 快 3.8%（t=0.38），**均不显著**：`batchSetAsync` 内部仍是 `spawn { req.wait() }`，跨线程唤醒次数一次未减，其收益只来自批量。全量 **378/378 通过** |
| 2026-10-06 | feat/v2-mmap-wal-vlog（未发版，分支） | **v2.0 阶段 1：WAL mmap 化 + 换段（rotate）**：新增 `Config.MmapWAL`（默认开，可回退 v1.x 的 `BufferedOutputStream` 路径）。mmap 后端把每个段按 arena 大小（2×MemTableSize）预分配并建立**段内固定映射**，写入直接 memcpy、`sync` 走 `msync(MS_SYNC)`（真正落盘；v1.x 的 `sync()` 只 flush 用户态缓冲、**没有 fsync**，故 `SyncWrites=true` 并不保证持久化）；段写满即换段（`<fid>.mem` → `<fid>.mem.N`），**不做运行中 remap**（go badger 的 `Truncate + remap` 自述存在段错误窗口，memtable.go:417）。**换段（原阶段 4）提前到本阶段**：单段固定容量一旦被残留 WAL 或恢复期重写打破，就会直接写失败，容量假设必须自带兜底。实现过程中修掉三个真实缺陷：① 读写打开带 `O_TRUNC`（Windows `CREATE_ALWAYS`）会清空已存在文件 → 崩溃恢复 replay 读到全 0（在 mmap-cj 三平台修复，v1.0.1）；② 已存在段的 `writeOffset` 若取文件长度，容量检查立即判满、写入全部失败 → 改为解析出的有效长度；③ 恢复期通过 `beginReplay/endReplay` 标记 memtable，避免把刚从 WAL 读出的数据再写回 WAL。新增用例 `testMmapWALRotatesWhenCapacityExceeded`（小容量强制换段：校验多段存在、条目完整且有序、关闭后各段已截断回收）；全量 **377/377 通过**。基准（`txn_queue_perf` 交替 A/B，各 24 样本）：小 value 0.906x（t=0.65，不显著）、大 value 4KB 1.020x（t=−2.31）——**换 mmap 在写吞吐上无实质收益**（成本主要在跨线程投递/唤醒、page fault 长尾），其价值在持久性语义，详见 benchmark-report §12 |
| 2026-10-02 | feat/ring-queue（未发版，分支） | **CloseableBlockingQueue 改单锁环形缓冲（抑制无效唤醒）**：原实现「LinkedBlockingQueue + 外挂 Mutex/Condition」每次 add 在入队后还要抢一次外层锁做 notify（即使无等待者），且队满时阻塞在 LBQ 内部、close 唤不醒它——新用例 `testBlockedProducerFailsOnClose` 在旧实现上 **超时 20s 挂起**（队满 + 消费者退出时生产者永久阻塞，违背 close 契约）。改为定长环形数组 + 单 Mutex + `notEmpty`/`notFull`：存取与判空/判满在同一临界区完成、通知按等待者计数按需下发、队满等待同时观察 closed；API 与语义不变（add 满阻塞 / close 后抛异常；remove 空阻塞 / close 排空后 None；tryRemove 非阻塞；size 精确）。新增 `CloseableBlockingQueueTest` 11 用例；全量 375/375 通过。端到端（新增 `txn_queue_perf` 示例：8 线程 × 5000 单键事务，两版二进制交替 A/B 各 9 轮）：平均 4567 vs 4956 ns/txn，**写吞吐 +7.8%**（最佳轮口径 +11.5%），配对比较 9/9 全胜 |
| 2026-10-02 | feat/reusable-latch（未发版，分支，**未采纳**） | **WriteRequest 完成信号复用化尝试（负结果，不合并）**：`SyncCounter` 无 `reset`，每次提交都要重建对象；chan-bench 微基准显示改用可复用 `Semaphore` 能把一次提交往返 1150→697ns（-39%）。端到端实测（`txn_queue_perf`，两版二进制交替 18 轮）：均值 4639.6 vs 4669.7 ns/txn（**-0.6%**）、中位数 -0.5%、逐轮配对 10/18、Welch t=-0.26、σ 412 vs 267 —— **无显著差异**。判定：微基准收益被真实写路径的其它开销稀释，不值得为此引入「Semaphore 许可钳制 + 必须严格一对一配对」的隐式约束，故不合并（证据与 6 个同步语义用例留在 `feat/reusable-latch` 分支）。**方法学**：这类微秒级差异必须交替测量并看分布——只看单轮最佳值，会把 8% 的真实提升和 0% 的无差异都测成「差不多」 |
| 2026-10-02 | exp/single-stage-write（未发版，分支，**未采纳**） | **单级写路径尝试（负结果，不合并）**：写路径原为两级队列——`writeCh` → `flushLoop` 批量收集 → `WritePipeline.queue` → pipeline 线程执行，`flushLoop` 只做「收集 + 转发」。实验让 `flushLoop` 直接处理批次（语义与 `WritePipeline.runBatch` 一致：异常整批 markFailed、finally 保证 done；全量 375/375 通过），实测（txn_queue_perf，两版二进制交替 18 轮）：均值 4631.7 vs 4702.0 ns/txn（**-1.5%**）、中位数 -1.7%、逐轮配对 7/9、**Welch t=-0.56（不显著）**、最佳轮反而略差（+1.0%）。判定：两级队列是有意的「收集与执行解耦」（pipeline 队列深度 1000 批，允许收集不被执行阻塞，合并后 flushLoop 串行执行会阻塞收集），收益不显著且破坏该流水线，**不采纳**（证据留在 `exp/single-stage-write` 分支）。 |
| 2026-10-02 | bench | **批量写收益量化（keysPerTxn 扫描）**：写路径的同步成本无法靠「内部批量提交」摊薄——唤醒次数 = 请求数（每个 commit 必须被单独唤醒），且 `flushLoop` 本就按 ≤1000 请求批量收集、批内一次 `runBatch`、逐个 `done()`。真正的杠杆在**用户侧事务粒度**：同一 40 万 key / 8 线程下，单键事务 **6778–6857 ns/key**，8 key/事务 **2216–2494 ns/key**（快 2.7–3.1x），64 key/事务 **1715–1969 ns/key**（快 3.5–4.0x）。`txn_queue_perf` 新增 `keysPerTxn` 参数与 `ns_per_key` 指标。附带风险提示：`batchSetAsync` 每批 `spawn` 一个等待线程，高频小批量会线程膨胀（与「每任务一线程」同源）。 |
| 2026-09-15 | v1.6.20 | **失败文案不再吞掉 OOM 身份（空 message 诊断闭环）**：忆时塔第三次写路径事故（维护任务每轮 `Job 0 failed:（空）`、写请求全失败、读路径正常、只能重启恢复）复盘确认「空 message 异常 ≈ OOM」签名——`OutOfMemoryError` 属 `Error` 层级且 message 常为空串，`runBatch` 的 `markFailed(e.message)` 原样透传 → `commitOrThrow` 抛 `Exception("")`，调用方与日志都拿不到任何线索（上一轮事故只能靠 GC 日志反推）。新增 `failureMsg`（Exception）/`systemFailureMsg`（Error，标注「系统级错误」）：message 为空时退回 `toString()`（含异常类型）；铺到 runBatch 两分支、loop/drain 边界打印、`writeOneRequest`。回归：`testSystemErrorDoesNotKillPipeline` 增加断言「OOM 批失败文案非空且含『系统级错误』」——无修复时该断言 FAILED（实测 `msg == ""`）。364/364 通过 |
| 2026-09-13 | fix/silent-failures（未发版，分支） | **静默 catch 审计：失败可见性补齐（7 处，纯日志、零语义变更）**：工作区 `scripts/scan-silent-catch.py` 扫 badger-cj 得 P0=1/P1=5/P3=7，逐个读码判定后修 7 处——① `db/wal.cj` 恢复路径三处（解码失败截断尾部、整事务丢弃、单条坏数据跳过）此前全无痕，各补 `println("[badger] ..." + e.toString())`；② `vlog/discard_stats.cj` 两处 `// Ignore errors`（load/flush）补日志；③ `db/badger.cj listMemFiles` 目录枚举失败 → 所有 .mem 被当作不存在 = WAL 静默不恢复，补告警；④ `io_uring/io_uring_pool.cj` io_uring 失败降级同步写（`catch (_)`，扫描器盲区）补「本进程已降级」痕迹（仅首次失败打印，保留 catch-all 与降级语义）；⑤ 示例 `iouring_batch_test`/`iouring_integration_test` 吞错 catch 补日志。判定「可接受不改」：`examples/perf/main.cj`（teardown 清理临时目录）、`db/iterator.cj:342`（ValueStruct 解析兜底）、`txn_perf`/`txn_scale_perf`/`txn_perf_long`（冲突已计数并打印）、`runVLogGC`/`compact` 的 `if (opt.InMemory) return`（正常提前返回，非异常吞掉）。扫描后 P0=0/P1=1/P3=4；`cjpm test -j 16` 改前 362/362 → 改后 362/362（无新增失败）；另用临时探针实测 WAL 坏尾部日志落地（`[badger] WAL decode failed at offset 88/120, truncating rest of WAL: IndexOutOfBoundsException: ...`）后删除探针 |
| 2026-09-05 | 观察 | **-j8 偶发归因证据链更新**：全库清除 `{j=>}` 闭包数组构造（读路径 entryOffsets/key 重建、bloom bits、skiplist 段——规避 cjc 缺陷 family，issue #3454）后，-j8 失败面从十余用例（读旧值/版本错/丢单 key，含纯内存用例）**收窄到仅 ConcurrentClose 偶发丢 1-2 条**（15 轮 3 轮）；加诊断重编译后连续 20 轮零失败——同一生产代码仅测试文件布局变化即改变触发，与 cjc 闭包构造缺陷「按调用点/文件形状生成错误代码」特征吻合（编译器缺陷为 -j8 偶发重要嫌疑，未定论）；ConcurrentClose 丢 1-2 条机制未复现定位（疑似 close 与最后写入竞态或编译器布局敏感），因重编译即消失无法稳定复现 |
| 2026-09-05 | v1.6.17-fix2 | **rotate 阶段化消除 OOM 中断窗口**（-j8 复现现场：flushMemTable 返回后 imm 残留/整批丢失但表生命周期完整）：rotate 原顺序 imm.add→新表构造（arena 分配 OOM 高发点）→入队，构造失败致表滞留 imm 且 mt 未切换（后续写进旧表、imm 重复引用）；修复为可抛步骤（reserve+构造）先于不可抛状态序列（imm.add+count+切换+入队），失败零变更。compactor 补 catch(Error) 边界。async 测试断言后置 close（失败不泄漏 db——此前失败用例泄漏放大出 51-109 个连锁 OOM）。**归因**：修复后 -j8 残余失败率与无 async-flusher 的旧版（081e96f）对照同档（旧版 4/16 轮 vs 新版 ~4/20 轮，失败用例高度重叠含纯内存用例），判定为仓库既有/环境级偶发（依赖多 TP 并行系统条件，单用例 240 次定向压力零复现），非本改动引入；async 引入的丢数据（rotate 窗口类）已由 e0d345b+本提交闭环 |
| 2026-09-05 | v1.6.18 | **全库 {j=>} 闭包数组构造规避 + 读路径加固**（cjc 缺陷 family，issue #3454）：block_iterator key 重建与 entryOffsets 索引解析、bloom filter 位表、skiplist 原子段、bench 数据构造全部改「repeat 占位 + 循环赋值」；新增大 key（30K/45K/60K）落盘重开双路径逐字节读回回归测试（testLargeKeyReconstructedByteExact）；crash_recovery 并发 close 用例加缺失 key 诊断。362 -j1 全绿；-j8 失败面从十余用例收窄至仅 1 例（编译布局敏感，归因编译器缺陷） |
| 2026-09-05 | v1.6.17-fix | **rotate+入队原子化修复并发数据丢失**（chronomem -j8 并行验证 + 本地 -j8 复现 3/6 轮）：putOneWithFlush 原「锁内 rotate → 锁外 flushQueue.add」两段式——rotate 后入队前抛 Error（OOM）→ 表滞留 imm 永不入队 = 已成功写入数据无人落盘（并发 close 下整批丢失：33/1305、28/200、300/1800、单 key）。修复：rotateAndEnqueueLocked 同写锁段原子入队（锁内 add 不阻塞：队列元素 ≤ immCount - flusher 手中 < 容量）；测试 InMemory 驻留内存收缩防进程堆 OOM。验证：-j1 361/361，-j8 修复后 11 轮 0 失败 0 OOM |
| 2026-09-05 | v1.6.17 | **flush 移出全局写锁异步化**（评审 P2-2 遗留闭环，对齐 badger-go flushChan/flushMemtable）：写路径/`flushMemTable()` 写锁内只轮换 memtable，SSTable 构建+落盘+MANIFEST+addTable 由单 flusher 协程锁外执行，完成后锁内出队 decrRef；队列深度=新 `Config.NumMemtables`（默认 5，对齐 go WithNumMemtables），超限写路径锁外等待背压；失败无限重试（Error 边界保活不杀 flusher）；close 时序重排（join flusher 先于拿写锁）后保留全量兜底落盘；`flushMemTable()` 保持同步语义（per-table 完成标志 + 空表 drain 在途）；**TableBuilder L1 单拷贝**：buf ArrayList 逐字节累积 → 分块持有 + finish 一次拼接（位级布局不变，golden 指纹回归），空表不再落盘空 .sst。测试 349→361；flush_impact 专项：运行期写吞吐 ~2x（46-47K→94-96K keys/s），close 毫秒级 |
| 2026-09-03 | v1.6.16 | ① **reverse seek 编码对齐 badger-go**（评审发现）：`Iterator.seek` 对 reverse 统一用 `keyWithTs(key, MaxUint64)`（反转后缀 0x00..00），而 badger-go Seek 对 reverse 用 `KeyWithTs(key, 0)`（反转后缀 0xFF..FF）——"≤ seekKey 的最后一条"二分需覆盖目标 user key 组全部版本条目才能命中，后缀 0x00..00 使目标组条目全部 > seekKey，seek 到表内存在的 key 漏掉该 key 自身（key1→[]、key2→[key1]），memtable 与磁盘 A/B 两侧同错故未被发现。修复：reverse 分支改用 ts=0 编码（后缀全 F），forward 保持 ts=Max；`testReverseSeekOnDiskTable` 增加绝对期望断言（seek 存在 key 必须包含自身，memtable 与磁盘双锚点；修复前 FAILED）。② **WritePipeline Error 批显式失败**（评审 P2 发现）：runBatch 系统级 Error（OOM）此前仅 loop() 边界捕获打印，本批 done() 未带失败标记 → commit() 误报 Ok = 静默丢写。修复：runBatch catch (e: Error) 与 Exception 同语义整批 markFailed（先于 finally done()）；`testSystemErrorDoesNotKillPipeline` 修复假阳性（原 handler 只读 size、-O2 死代码消除使 OOM 从未真正发生）——sink 逃逸 + touch 首字节稳定触发真实 OOM，新增断言 OOM 批 errorOf Some、管道存活后续正常批无失败标记；349 测试通过 |
| 2026-09-03 | v1.6.15 | 磁盘表**正向 seek 跨 block 间隙漏条目**（tsdb key 编码 v1→v2 迁移演练发现：重建库块布局变化使「组前缀型 seek」——seekKey 大于前一块全部条目、小于下一块首条——落入两 block 间隙）：Table.findBlock 只按「块首 key」二分定位，此类 seekKey 被指回前一块 → 块内二分 miss → 迭代 invalid，漏掉 ≥ seekKey 的首条目（此前 R3 修复只覆盖 seekKey 与块首同 user key 的版本场景，通用间隙 case 未覆盖）。修复 `TableIterator.seek`：块内 seek invalid 且存在下一块时推进到下一块 `seekToFirst`（reverse 场景由 TableIterWrapper.seek 对 > key 结果 prev 收尾——落点恰为其想要的 ≤ key 最后一条，一并受益）。回归测试 `testForwardSeekAcrossBlockGap`（memtable vs flush 落盘 A/B：2400 定长 key 跨数十 4KB block，6 组前缀 + 地毯式逐 key 剥尾 seek 逐项相等；修复前 FAILED）；349 测试通过 |
| 2026-09-02 | v1.6.14 | 磁盘表 reverse seek/迭代修复（tsdb 游标分页联调发现）：① `TableIterWrapper.seek` reverse 语义对齐 MemTableIterator——forward seek 定位后若 key 大于全部则 seekLast、落在两 key 间则 prev 一步（此前直接透传前向 seek：seek key 大于表内全部 key 时 reverse 迭代空结果、两 key 之间时起点偏大）；② `Iterator.valid()` 改以 parseItem 产出状态 itemValid 判定（此前看 iitr.valid()：collectReverseLatest 消费完表内最后一段版本链、无 finTxn 垫底 key 时 iitr 越界 invalid，reverse 全量迭代吞最后一项）。回归测试 `testReverseSeekOnDiskTable`（memtable vs flush 落盘 A/B 对照 6 个 seek 目标逐项相等）；348 测试通过 |
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