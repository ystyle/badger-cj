# Badger-cj 项目进度跟踪

**最后更新：** 2026-03-12  
**当前阶段：** ✅ Phase 5 已完成（无锁并发 + 持久化）

---

## 项目状态

| 指标 | 状态 |
|------|------|
| **测试** | 181/181 通过 ✅ |
| **性能** | Write 457ns/op (Go 1.8x), Read 116ns/op (Go 1.2x) |
| **核心功能** | 全部完成（见下方清单） |

---

## Phase 完成记录

| Phase | 完成时间 | 测试数 | 核心成果 |
|-------|----------|--------|---------|
| **Phase 1** | 2025-03-08 | 33 | CRC32/Varint/Arena/Skiplist 基础设施 |
| **Phase 2** | 2026-03-08 | 60 | SSTable/VLog/MANIFEST 存储引擎 |
| **Phase 3** | 2026-03-08 | 89 | MemTable/WAL/LevelsController/DB/Compaction |
| **Phase 4** | 2026-03-09 | 126 | Oracle/WaterMark/SSI/Iterator/Snapshot/MVCC |
| **Phase 5** | 2026-03-11 | 166 | 性能优化 + 无锁并发 SkipList + DB 持久化 |

---

## 已实现功能

### 核心功能 ✅
- [x] KV 存储 (Get/Set/Delete)
- [x] MemTable (基于 Skiplist)
- [x] WAL (Write-Ahead Log)
- [x] SSTable (带前缀压缩)
- [x] Value Log (大值分离存储)
- [x] MANIFEST (元数据管理)
- [x] Compaction (L0→L1 压缩)

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

**测试环境：** 16 线程，5000 ops，4GB heap

| 操作 | Go Badger | Cangjie badger-cj | 比率 |
|------|-----------|-------------------|------|
| Concurrent Write | ~250 ns/op | 457 ns/op | **1.8x** |
| Concurrent Read | ~96 ns/op | 116 ns/op | **1.2x** |
| DB Set | 4,566 ns/op | 14,730 ns/op | **3.2x** |
| DB Get | 708 ns/op | 3,901 ns/op | **5.5x** |

---

## Phase 6 计划（可选扩展）

> **状态：** 🟡 进行中 (P1: 2/7 完成)

### P1: 完善测试 (~14h)

| 任务 | 预估 | 状态 |
|------|------|------|
| SSTable 读写集成测试 | 2h | ✅ |
| Value Log 读写集成测试 | 1h | ✅ |
| 完整数据库生命周期测试 | 1h | ❌ |
| WAL 崩溃恢复压力测试 | 2h | ❌ |
| Go 行为对比测试 | 4h | ❌ |
| 边界情况验证 | 2h | ❌ |
| 兼容性报告 | 2h | ❌ |

### P2: 扩展功能 (~18h)

| 任务 | 预估 | 状态 |
|------|------|------|
| Managed DB (手动管理时间戳) | 6h | ❌ |
| Stream API (大规模数据处理) | 8h | ❌ |
| Transaction View (回调式只读事务) | 2h | ❌ |
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
| v6.0 | 2026-03-11 | 重构文档结构，精简冗余内容；添加 io_uring 优化设计（待审核） |
| v5.2 | 2026-03-11 | Phase 5.5/5.6 完成（无锁并发 + 持久化） |
| v5.0 | 2026-03-10 | Phase 5 完成，性能优化 |
| v4.0 | 2026-03-09 | Phase 4 完成，MVCC + Snapshot |
| v3.0 | 2026-03-08 | Phase 3 完成，核心功能 |
| v2.0 | 2026-03-08 | Phase 2 完成，存储引擎 |
| v1.0 | 2025-03-08 | Phase 1 完成，基础设施 |
