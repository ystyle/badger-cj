# Badger-cj 项目进度跟踪

**最后更新：** 2026-03-15  
**当前阶段：** ✅ P1 API 扩展已完成（Config with*/DB info/validForPrefix）

---

## 项目状态

| 指标 | 状态 |
|------|------|
| **测试** | 243/243 通过 ✅ |
| **性能** | 直接写入 ~616K keys/s，事务写入 ~400-441K keys/s |
| **核心功能** | 全部完成 |
| **API 对齐** | P0+P1 完成，对齐率 ~75% |

---

## P1: API 扩展（Config + DB Info + Iterator）✅ 已完成

| 任务 | 状态 | 描述 |
|------|------|------|
| Config with* 链式方法 | ✅ | withDir/withMemTableSize/withDisableWAL 等 12 个方法 |
| DB.isClosed() | ✅ | 检查数据库是否已关闭 |
| DB.sync() | ✅ | 同步 WAL 和 VLog 到磁盘 |
| DB.size() | ✅ | 返回 LSM 和 VLog 大小 |
| DB.tables() | ✅ | 返回所有 SSTable 信息 |
| DB.levels() | ✅ | 返回所有 Level 信息 |
| Iterator.validForPrefix() | ✅ | 检查当前 key 是否匹配前缀 |

### 新增文件

| 文件 | 说明 |
|------|------|
| `src/db/db_info.cj` | SSTableInfo/LevelInfo/DBSize 数据类 |
| `src/db/p1_api_test.cj` | P1 API 测试（17 个用例） |

### 测试覆盖

| 测试类 | 用例数 | 覆盖内容 |
|--------|--------|----------|
| P1ConfigWithTest | 6 | withDir/withMemTableSize/withDisableWAL/链式调用 |
| P1DBInfoApiTest | 5 | isClosed/size/tables/levels/sync |
| P1ValidForPrefixTest | 2 | 前缀匹配/无匹配情况 |

### 功能验证

- Config 链式配置：`Config().withDir("/tmp").withDisableWAL(true)` ✅
- DB 信息查询：`db.size()`, `db.tables()`, `db.levels()` ✅
- Iterator 前缀迭代：`iter.seek(prefix); while(iter.validForPrefix(prefix))` ✅

---

## P0: API 对齐（TTL + 异常 + Item）✅ 已完成

| 任务 | 状态 | 描述 |
|------|------|------|
| BadgerException | ✅ | 异常类 + ErrorCode 枚举 |
| Entry 重构 | ✅ | meta/userMeta 分离 + withTTL/withMeta/withDiscard |
| WriteEntry 扩展 | ✅ | meta/userMeta/expiresAt 字段 |
| isDeletedOrExpired | ✅ | 过期检查辅助函数 |
| 读取路径过期检查 | ✅ | badger.cj, iterator.cj |
| 写入路径传递 | ✅ | 传递 meta/userMeta/expiresAt |
| Compaction 过期过滤 | ✅ | 跳过过期数据 |
| VLog GC 过期丢弃 | ✅ | DiscardChecker 回调 |
| Item 完整 API | ✅ | keyCopy/valueCopy/size/isDeletedOrExpired |
| IteratorOptions | ✅ | 完整字段 + DefaultIteratorOptions |

### 新增文件

| 文件 | 说明 |
|------|------|
| `src/db/exception.cj` | 异常类 |
| `src/db/entry.cj` | Entry 类（从 badger.cj 分离） |
| `src/db/ttl_e2e_test.cj` | TTL 端到端测试（10 个用例） |
| `src/db/entry_test.cj` | Entry API 测试 |
| `src/db/item_api_test.cj` | Item API 测试 |

### 测试覆盖

| 测试类 | 用例数 | 覆盖内容 |
|--------|--------|----------|
| TTLE2ETest | 10 | 过期读取、迭代器跳过、Compaction 清理、userMeta 传递 |
| EntryTest | 7 | withMeta/withTTL/withDiscard/静态工厂 |
| ItemApiTest | 9 | keyCopy/valueCopy/size/discardEarlierVersions |
| HelpersTest | 9 | isDeletedOrExpired/discardEntry |
| ExceptionTest | 11 | ErrorCode/消息/静态工厂 |

### 功能验证

- TTL 写入读取：过期数据返回 None ✅
- Compaction 清理过期数据 ✅
- VLog GC 丢弃过期条目 ✅
- userMeta 正确传递 ✅
- withDiscard 设置内部 meta 位 ✅

---

## Phase 7: 完整 Compaction + VLog GC ✅ 已完成

### P0: 完整 Compaction (~16h) ✅

| 任务 | 预估 | 状态 | 描述 |
|------|------|------|------|
| keyRange 计算 | 2h | ✅ | 计算表的 key 范围 |
| 重叠表查找 | 2h | ✅ | 找到 L0/L1 重叠的表 |
| 迭代器合并 | 3h | ✅ | MergeIterator 合并多个 SSTable |
| 丢弃删除标记 | 2h | ✅ | Compaction 时清理 tombstone |
| 丢弃旧版本 | 2h | ✅ | 只保留最新版本 |
| 写入新 SSTable | 2h | ✅ | compactBuildTables 生成新表 |
| 更新 MANIFEST | 2h | ✅ | deleteTables 替换表 |
| 单元测试 | 3h | ✅ | CompactionTest 验证正确性 |
| Compactor 后台协程 | 2h | ✅ | 自动触发 Compaction |
| compact() 手动接口 | 1h | ✅ | 用户可手动触发完整 Compaction |

### P1: VLog GC 完整实现 (~12h) ✅

| 任务 | 预估 | 状态 | 描述 |
|------|------|------|------|
| DiscardStats 类 | 2h | ✅ | 跟踪每个 VLog 文件的垃圾统计 |
| VLogGCDB 接口 | 1h | ✅ | 打破 Badger/VLogManager 循环依赖 |
| iterate() 遍历 | 1h | ✅ | 遍历 VLog 文件所有 entry |
| pickLog() 选择 | 1h | ✅ | 选择垃圾比例最高的文件 |
| rewrite() 重写 | 3h | ✅ | 重写有效 entry 到新文件 |
| Badger 集成 | 1h | ✅ | 实现 VLogGCDB 接口 + updateDiscardStats |
| 单元测试 | 3h | ✅ | VLogGCTest + VLogManagerGCTest 验证 |

---

## Phase 完成记录

| Phase | 完成时间 | 测试数 | 核心成果 |
|-------|----------|--------|---------|
| **Phase 1** | 2025-03-08 | 33 | CRC32/Varint/Arena/Skiplist 基础设施 |
| **Phase 2** | 2026-03-08 | 60 | SSTable/VLog/MANIFEST 存储引擎 |
| **Phase 3** | 2026-03-08 | 89 | MemTable/WAL/LevelsController/DB/Compaction |
| **Phase 4** | 2026-03-09 | 126 | Oracle/WaterMark/SSI/Iterator/Snapshot/MVCC |
| **Phase 5** | 2026-03-11 | 166 | 性能优化 + 无锁并发 SkipList + DB 持久化 |
| **Phase 6** | 2026-03-12 | 182 | 性能深度优化 + 独立基准测试程序 |
| **Phase 7** | 2026-03-14 | 194 | 完整 Compaction + VLog GC + 性能修复 |

---

## 已实现功能

### 核心功能 ✅
- [x] KV 存储 (Get/Set/Delete)
- [x] MemTable (基于 Skiplist)
- [x] WAL (Write-Ahead Log)
- [x] SSTable (带前缀压缩)
- [x] Value Log (大值分离存储)
- [x] MANIFEST (元数据管理)
- [x] Compaction (完整多层级 L0→L1→...→L6)
- [x] VLog GC (后台自动回收)

### 事务系统 ✅
- [x] Oracle 全局时间戳管理
- [x] WaterMark 完成追踪
- [x] SSI 可串行化快照隔离
- [x] 冲突检测
- [x] Read-your-writes 语义

### 迭代器 ✅
- [x] 前向/反向迭代
- [x] Seek 定位
- [x] 前缀过滤
- [x] 删除标记处理
- [x] 版本去重

### MVCC ✅
- [x] 时间戳嵌入 (XOR 反转)
- [x] 版本过滤
- [x] Snapshot 快照读
- [x] 一致性范围扫描

### 并发与持久化 ✅
- [x] 无锁并发 SkipList (真 CAS)
- [x] DB.close() flush 到 SSTable
- [x] DB.open() 恢复 (MANIFEST/SSTable/WAL)
- [x] 崩溃恢复

---

## 性能对比

**测试环境：** 12GB heap

| 操作 | Go Badger | Cangjie badger-cj | 比率 |
|------|-----------|-------------------|------|
| 直接写入 (disableWAL) | ~1.5M keys/s | **616K keys/s** | **2.4x** ✅ |
| 事务写入 (50并发) | ~1.0M keys/s | **400-441K keys/s** | **2.5x** ✅ |
| DB Get | ~1 µs | **2.9 µs** | **2.9x** ✅ |
| DB Set | ~5 µs | **7.4 µs** | **1.5x** ✅ |

**事务写入测试 (50 并发)：**

| 规模 | 耗时 | 吞吐量 |
|------|------|--------|
| 50 x 100 = 5,000 keys | 11ms | **441K keys/s** |
| 50 x 1000 = 50,000 keys | 125ms | **399K keys/s** |
| 50 x 3000 = 150,000 keys | 377ms | **397K keys/s** |

**关键优化项：**

| 优化 | 效果 |
|------|------|
| AtomicStorage 分段扩展 | 初始化从 12% 降到 <1% |
| Arena.putBytes/getBytes 使用 copyTo | 批量拷贝替代逐字节 |
| Node.compareKey 直接访问 Arena buffer | 避免 Node 对象创建 |
| Skiplist::add 内联优化 | 减少 50% Node 对象创建 |
| CRC32C 全局查找表 | 从 17% 开销降到 0.04% |
| 移除写入路径 updateDiscardStats | 性能提升 2-3x |
| Option<WAL> 替代 dummy() hack | 代码更清晰 |

---

## Phase 6 计划（性能优化 + 扩展）

> **状态：** ✅ P0 已完成 (9/9)，独立基准测试程序已创建

### P0: 性能优化 (~16h) ✅

| 任务 | 预估 | 状态 | 实际收益 |
|------|------|------|---------|
| WriteChannel 零延迟通知 (Condition) | 4h | ✅ | 大事务提升 ~40% |
| 请求对象池化复用 | 2h | ✅ | 小事务提升 ~10% |
| 移除不必要的写锁 | 2h | ✅ | 基本持平 |
| keyWithTs 减少内存分配 | 1h | ✅ | 略有提升 |
| ValueStruct/ValuePointer encode 优化 | 1h | ✅ | 略有提升 |
| LogEntry.encode/safeCopy 优化 | 1h | ✅ | 大事务提升 50-60% |
| Varint/BlockBuilder/BloomFilter 优化 | 1h | ✅ | 略有提升 |
| WritePipeline 零延迟通知 | 1h | ✅ | 略有提升 |
| MemTableIterator 延迟初始化 | 1h | ✅ | 正向迭代 O(1) 初始化 |

### P0.5: 独立基准测试程序 ✅

| 任务 | 状态 |
|------|------|
| 创建 `src/examples/txn_perf/` 可执行程序 | ✅ |
| 千位分隔符格式化输出 | ✅ |
| ns/op + keys/s 双统计 | ✅ |
| 总执行时间统计 | ✅ |

**运行命令：**
```bash
cjHeapSize=12gb ./target/release/bin/badgercj.examples.txn_perf
```

**输出格式：**
```
WRITE: 50 x 3,000 = 150,000 keys in 1156ms, 7,710 ns/op, 129,697 keys/s (ok: 50, fail: 0)
TOTAL: 80864ms
```

**关键发现：** 仓颉 `@Bench` 框架对有状态操作不稳定（误差 2000-3000%），独立可执行程序更适合 DB 性能测试。

### P1: 完善测试 (~14h)

| 任务 | 预估 | 状态 |
|------|------|------|
| SSTable 读写集成测试 | 2h | ✅ |
| Value Log 读写集成测试 | 1h | ✅ |
| 完整数据库生命周期测试 | 1h | ✅ |
| WAL 崩溃恢复压力测试 | 2h | ❌ |
| Go 行为对比测试 | 4h | ❌ |
| 边界情况验证 | 2h | ❌ |
| 兼容性报告 | 2h | ❌ |

### P2: 扩展功能 (~18h)

| 任务 | 预估 | 状态 |
|------|------|------|
| Managed DB (手动管理时间戳) | 6h | ❌ |
| Stream API (大规模数据处理) | 8h | ❌ |
| Transaction View (回调式只读事务) | 2h | ✅ |
| Iterator 预取优化 | 2h | ❌ |
| io_uring I/O 优化 | 26h | 📋 待审核 |

### P3: 文档与发布 (~8h)

| 任务 | 预估 | 状态 |
|------|------|------|
| 用户指南 | 2h | ❌ |
| API 文档 | 2h | ❌ |
| 性能调优指南 | 1h | ❌ |
| CHANGELOG + Release Notes | 3h | ❌ |

---

## 技术决策记录

| 问题 | 解决方案 | 文件 |
|------|---------|------|
| 仓颉无 unsafe.Pointer | 使用 UInt32 offset 索引 Arena | `src/arena/arena.cj` |
| ByteBuffer 不支持随机访问 | 使用 Array<Byte> + AtomicUInt32 | `src/arena/arena.cj` |
| 仓颉无 FlatBuffers/Protobuf | 手动实现兼容编码 | `src/table/table_index.cj` |
| 仓颉无 `~` 按位取反 | 使用 XOR: `0xFFFF... ^ ts` | `src/db/helpers.cj` |
| Iterator 前缀匹配 bug | 移除 valid() 中冗余 parseKey() | `src/db/iterator.cj` |
| getWithTs O(n) 性能 | 使用 findGe O(log n) | `src/skiplist/skiplist.cj` |
| SkipList 伪 CAS 不安全 | 新增 AtomicStorage 真正 CAS | `src/skiplist/atomic_storage.cj` |
| DB 不支持持久化 | close() flush + open() 恢复 | `src/db/db.cj` |
| AtomicStorage 容量不足 | 动态计算 `arenaSize / 32` | `src/db/memtable.cj` |
| MemTableSize 默认太小 | 改为 64MB (与 Go badger 一致) | `src/db/options.cj` |
| hashKey 整数溢出 | 添加 `@OverflowWrapping` 注解 | `src/db/iterator.cj` |
| Iterator.seek 找错 key | 使用 MaxUint64 而不是 0 作为时间戳 | `src/db/iterator.cj` |
| MemTableIterator 初始化慢 | 延迟迭代：正向 O(1)，反向保留预加载 | `src/db/memtable_iterator.cj` |
| AtomicStorage 预分配太慢 | 分段扩展 + 按需分配 | `src/skiplist/atomic_storage.cj` |
| Node.compareKey 每次创建 Node | 直接访问 Arena buffer | `src/skiplist/skiplist.cj` |
| CRC32C 每次创建查找表 | 使用全局查找表 | `src/encoding/crc32.cj` |
| LogEntry::encode 逐字节拷贝 | 使用 copyTo 批量拷贝 | `src/vlog/entry.cj` |
| Skiplist.add 比较方向错误 | cmp < 0 继续，cmp > 0 停止 | `src/skiplist/skiplist.cj` |
| VLog GC 循环依赖 | 定义 VLogGCDB 接口打破 Badger/VLogManager 循环 | `src/vlog/vlog_gc_db.cj` |
| VLog GC 数据丢失风险 | 完整 rewrite：检查 LSM ValuePointer 匹配后重写 | `src/vlog/vlog_manager.cj` |
| lambda 捕获可变变量 | 使用 Counter 包装类 | `src/vlog/vlog_gc_test.cj` |
| updateDiscardStats 性能问题 | 移除写入路径调用，Go Badger 也没有在写入时统计 | `src/db/badger.cj` |
| Array repeat: 初始化引用类型 | Atomic 类型必须用闭包初始化，否则共享对象 | `src/skiplist/atomic_storage.cj` |
| Option<WAL> 替代 dummy() | 使用 Option 类型更安全，wal?.delete() 自动跳过 | `src/db/memtable.cj` |
| db.get 使用错误 readTs | 应使用 `oracle.currentTs()` 而非 `version.load()` | `src/db/badger.cj` |
| oracle 恢复后 ts 未初始化 | Badger.open 需调用 `oracle.initTs()` 设置正确起始时间戳 | `src/db/oracle.cj` |
| Compaction 未持久化 | doCompact 需写 SSTable 文件 + 更新 MANIFEST + 删除旧表记录 | `src/db/compaction.cj` |

### 仓颉语法注意事项

- `AtomicUInt32.fetchAdd()` 返回**旧值**，不是新值
- `let` 定义常量，不是 `const`
- Array 初始化：`Array<T>(size, repeat: value)`
- ArrayList 添加：`.add()` 不是 `.append()`
- spawn 返回 `Future<Unit>`，忽略用 `let _ =`
- `while(true)` 循环需确保所有路径有返回值
- `let` 变量在 while 内不能重新赋值，需用 `var`

---

## 文档索引

**设计文档：**
- `docs/plans/2025-03-07-badger-cj-port-design.md` - 总体移植设计
- `docs/plans/2026-03-08-phase3-core-functionality-design.md` - Phase 3 设计
- `docs/plans/2026-03-08-phase4-transaction-design.md` - Phase 4 事务设计
- `docs/plans/2026-03-09-phase5-optimization-design.md` - Phase 5 优化设计
- `docs/plans/2026-03-10-lockfree-skiplist-design.md` - 无锁并发设计
- `docs/plans/2026-03-10-db-persistence-design.md` - 持久化设计
- `docs/plans/2026-03-11-iouring-optimization-design.md` - io_uring I/O 优化设计 (📋 待审核)

**分析文档：**
- `docs/badger-analysis/01-file-formats.md` - SSTable/VLog/MANIFEST 格式
- `docs/badger-analysis/02-algorithms.md` - LSM-Tree/Compaction 算法
- `docs/badger-analysis/06-arena-bytebuffer-analysis.md` - Arena/ByteBuffer 分析

---

## 更新历史

| 版本 | 日期 | 变更 |
|------|------|------|
| v7.6 | 2026-03-15 | P1 完成：Config with* 链式方法、DB 信息查询 API (isClosed/sync/size/tables/levels)、Iterator.validForPrefix，245 测试全部通过 ✅ |
| v7.5 | 2026-03-14 | 修复 Compaction/readTs/oracle 恢复 bug：db.get 使用 oracle.currentTs()、oracle.initTs() 初始化、doCompact 持久化 SSTable+MANIFEST，194 测试全部通过 ✅ |
| v7.4 | 2026-03-14 | 修复性能回归：移除 updateDiscardStats、修复 Atomic 初始化，194 测试通过 |
| v7.3 | 2026-03-13 | VLog GC 完整实现：DiscardStats/VLogGCDB接口/iterate/pickLog/rewrite，28/28 vlog 测试通过 |
| v7.2 | 2026-03-13 | Phase 7 完成：完整多层级 Compaction + VLog GC，171 测试通过 |
| v7.1 | 2026-03-13 | VLog GC 简化实现：getDiscardRatio/runGC + 后台协程 + 测试 |
| v7.0 | 2026-03-13 | Compaction 选择逻辑 (getKeyRange, pickCompaction, fillTables, doCompact) |
| v6.3 | 2026-03-13 | 重命名 DB->Badger, DBOptions->Config；确认 view/update API 已实现 |
| v6.2 | 2026-03-13 | 修复 Skiplist.add 比较方向 bug，测试从 29 失败恢复到全部通过 |
| v6.1 | 2026-03-12 | Phase 6 深度优化完成，性能从 103K 提升到 680K keys/s (6.6x)，WAL 优化 +92% |
| v6.0 | 2026-03-11 | 重构文档结构，精简冗余内容；添加 io_uring 优化设计（待审核） |
| v5.2 | 2026-03-11 | Phase 5.5/5.6 完成（无锁并发 + 持久化） |
| v5.0 | 2026-03-10 | Phase 5 完成，性能优化 |
| v4.0 | 2026-03-09 | Phase 4 完成，MVCC + Snapshot |
| v3.0 | 2026-03-08 | Phase 3 完成，核心功能 |
| v2.0 | 2026-03-08 | Phase 2 完成，存储引擎 |
| v1.0 | 2025-03-08 | Phase 1 完成，基础设施 |
