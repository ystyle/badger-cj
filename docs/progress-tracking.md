# Badger-cj 项目进度跟踪

**最后更新：** 2026-03-20  
**当前阶段：** ✅ P0 BloomFilter 已完成

---

## 项目状态

| 指标 | 状态 |
|------|------|
| **测试** | 252/252 通过 ✅ |
| **性能** | 直接写入 ~616K keys/s，事务写入 ~400-441K keys/s |
| **API 对齐** | P0+P1 完成，对齐率 ~80% |

---

## 已完成阶段

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

---

## 性能

| 操作 | Go Badger | badger-cj | 比率 |
|------|-----------|-----------|------|
| 直接写入 | ~1.5M keys/s | 616K keys/s | 2.4x |
| 事务写入 (50并发) | ~1.0M keys/s | 400K keys/s | 2.5x |
| DB Get | ~1 µs | 2.9 µs | 2.9x |
| DB Set | ~5 µs | 7.4 µs | 1.5x |

---

## 待实现功能

| 功能 | 优先级 | 说明 |
|------|--------|------|
| io_uring | P0 | Linux 文件写入优化 |
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

> 详细技术决策、仓颉语言陷阱、优化经验见 [cangjie-lessons-learned.md](./cangjie-lessons-learned.md)

---

## 文档索引

- `README.md` - 使用指南
- `docs/api-alignment-report.md` - API 对齐详情
- `docs/benchmark-report.md` - 性能测试
- `docs/plans/` - 设计文档
- `docs/badger-analysis/` - 算法分析

---

## 更新历史

| 日期 | 版本 | 变更 |
|------|------|------|
| 2026-03-20 | v7.7 | P0 BloomFilter 完成：TableBuilder/Table 集成，默认 1% 误判率，252 测试通过 |
| 2026-03-15 | v7.6 | P1 完成：Config with*/DB info/validForPrefix |
| 2026-03-15 | v7.5 | P0 完成：TTL/异常/Item API |
| 2026-03-14 | v7.4 | Phase 7 完成：Compaction + VLog GC |
| 2026-03-12 | v7.3 | Phase 6 完成：性能优化 |
| 2026-03-11 | v7.2 | Phase 5 完成：持久化 |
| 2026-03-09 | v7.1 | Phase 4 完成：事务系统 |
| 2026-03-08 | v7.0 | Phase 2-3 完成：存储引擎 + 核心功能 |
| 2025-03-08 | v1.0 | Phase 1 完成：基础设施 |