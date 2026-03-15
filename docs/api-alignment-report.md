# Badger-cj API 对齐报告（深度评估版）

**最后更新：** 2026-03-15  
**P0 状态：✅ 已完成**

## 概述

| 模块 | Go API 数量 | 仓颉已实现 | 对齐率 | P0 状态 |
|------|-------------|------------|--------|---------|
| DB | 37 | 15 | 40% | ✅ TTL 已实现 |
| Txn | 9 | 7 | 78% | ✅ setEntry 已实现 |
| Item | 12 | 9 | 75% | ✅ 完整 API |
| Entry | 5 | 5 | 100% | ✅ withTTL/withMeta/withDiscard |
| Iterator | 7 | 5 | 71% | ✅ |
| IteratorOptions | 6 | 6 | 100% | ✅ |
| BadgerException | 9 | 9 | 100% | ✅ 新增 |

### P0 新增测试

- `src/db/ttl_e2e_test.cj` - 10 个 TTL 端到端测试
- `src/db/entry_test.cj` - Entry API 测试
- `src/db/item_api_test.cj` - Item API 测试

---

## P0 实现总结

### Entry 设计关键决策

**分离 meta 和 userMeta**：

```cangjie
public class Entry {
    public let key: Array<Byte>
    public let value: Array<Byte>
    public let meta: Byte           // 内部标记
    public let userMeta: Byte       // 用户自定义标记
    public let expiresAt: UInt64    // 过期时间
}
```

**原因**：如果 `userMeta` 用于判断 `isDelete()`，用户设置 `withMeta(0x55)` 会触发误删（0x55 包含 bitDelete 位）。

### TTL 实现路径

```
Entry.withTTL(dur)
    ↓ 写入传递 expiresAt
ValueStruct 存储
    ↓ 读取检查
isDeletedOrExpired() → 返回 None
    ↓ Compaction 清理
过滤过期数据
    ↓ VLog GC 清理
discardEntry() 回调
```

---

## 功能实现依赖分析

### 1. Entry withMeta/withTTL/withDiscard ✅ 已完成

**实际改动**：

| 文件 | 改动内容 |
|------|----------|
| `src/db/entry.cj` | Entry 类，meta/userMeta 分离 |
| `src/db/write_request.cj` | WriteEntry 添加 meta 字段 |
| `src/db/badger.cj` | 写入路径传递 meta/userMeta/expiresAt |
| `src/db/transaction.cj` | TxnEntry 添加 entryMeta 字段 |
| `src/db/helpers.cj` | isDeletedOrExpired(), discardEntry() |
| `src/db/iterator.cj` | 过期检查 |
| `src/db/compaction.cj` | 过期过滤 |
| `src/vlog/gc_file_rewriter.cj` | DiscardChecker 回调 |

---

### 2. Item 完整 API ✅ 已完成
```

当前仓颉实现在创建 Item 时已加载值，不支持懒加载。

**涉及文件**:

| 文件 | 改动内容 | 代码量 |
|------|----------|--------|
| `item.cj` | 添加方法 | ~40 行 |
| `iterator.cj` | 支持懒加载（可选） | ~50 行 |
| **总计** | | ~40-90 行 |

**工作量**: 0.5-1 天（不含懒加载）/ 2-3 天（含懒加载）

---

### 3. WriteBatch 批量写入

**表面改动**: 新模块 (~100 行)

**实际依赖**:

```
WriteBatch
    ↓
事务机制: Transaction ← 已有
    ↓
批量提交优化: 
  - 减少锁竞争
  - 合并多个写入
  - 异步回调
    ↓
Oracle 时间戳分配 ← 已有
    ↓
回滚机制:
  - 记录已写入条目
  - cancel() 时反向删除
```

**涉及文件**:

| 文件 | 改动内容 | 代码量 |
|------|----------|--------|
| `write_batch.cj` | 新模块 | ~150 行 |
| `badger.cj` | `newWriteBatch()` | ~10 行 |
| `badger.cj` | `newWriteBatchAt()` | ~10 行 |
| 测试文件 | 批量写入测试 | ~100 行 |
| **总计** | | **~270 行** |

**工作量**: 2-3 天

---

### 4. Stream API

**表面改动**: 新模块 (~150 行)

**实际依赖**:

```
Stream.orchestrate()
    ↓
并发迭代:
  - 按 key range 分片
  - 多线程并行处理
  - 结果合并
    ↓
回调机制:
  - chooseKey: 过滤 key
  - keyToList: 转换数据
  - send: 发送结果
    ↓
KVList 序列化:
  - protobuf 或自定义格式
    ↓
Context 取消:
  - 仓颉无标准 Context
  - 需自定义取消机制
```

**关键挑战**:

1. **并发分片**: 需要计算 key range 分布
2. **回调并发安全**: chooseKey/keyToList 可被多线程调用
3. **Context**: 仓颉无标准取消机制，需自己实现
4. **KVList**: 需要序列化格式

**涉及文件**:

| 文件 | 改动内容 | 代码量 |
|------|----------|--------|
| `stream.cj` | 新模块 | ~200 行 |
| `kv_list.cj` | KVList 数据结构 | ~50 行 |
| `context.cj` | 取消上下文 | ~50 行 |
| `badger.cj` | `newStream()` | ~10 行 |
| `levels.cj` | key range 计算 | ~30 行 |
| 测试文件 | Stream 测试 | ~150 行 |
| **总计** | | **~490 行** |

**工作量**: 5-7 天

---

### 5. MergeOperator 合并操作

**表面改动**: 新模块 (~80 行)

**实际依赖**:

```
MergeOperator
    ↓
定时合并:
  - 后台 goroutine 循环
  - 每隔 dur 时间执行合并
    ↓
读取-合并-写入:
  - get(): 读取当前值
  - add(val): 执行合并 f(current, val)
  - 写回数据库
    ↓
并发安全:
  - 多个 add() 调用需要串行化
    ↓
停止机制:
  - stop() 停止后台任务
```

**涉及文件**:

| 文件 | 改动内容 | 代码量 |
|------|----------|--------|
| `merge_operator.cj` | 新模块 | ~100 行 |
| `badger.cj` | `getMergeOperator()` | ~10 行 |
| 测试文件 | 合并操作测试 | ~80 行 |
| **总计** | | **~190 行** |

**工作量**: 2-3 天

---

### 6. Sequence 序列生成

**表面改动**: 新模块 (~50 行)

**实际依赖**:

```
Sequence
    ↓
原子递增:
  - 内存中维护当前值
  - 带宽预分配（一次分配 bandwidth 个）
    ↓
持久化:
  - key 存储当前序列号
  - 重启后恢复
    ↓
并发安全:
  - 多线程调用 next() 原子递增
    ↓
释放机制:
  - release() 归还未使用的序列号
```

**涉及文件**:

| 文件 | 改动内容 | 代码量 |
|------|----------|--------|
| `sequence.cj` | 新模块 | ~80 行 |
| `badger.cj` | `getSequence()` | ~10 行 |
| 测试文件 | 序列测试 | ~60 行 |
| **总计** | | **~150 行** |

**工作量**: 1-2 天

---

### 7. Config with* 链式方法

**表面改动**: 添加方法 (~200 行)

**实际依赖**:

```
Config.withXxx(val)
    ↓
返回新 Config 对象（不可变模式）
    ↓
或修改当前对象（可变模式）
```

**问题**: 当前 Config 使用 `let` 字段，不可变。需要改为 `var` 或返回新对象。

**涉及文件**:

| 文件 | 改动内容 | 代码量 |
|------|----------|--------|
| `config.cj` | 添加 with* 方法 | ~200 行 |
| 测试文件 | 链式配置测试 | ~50 行 |
| **总计** | | **~250 行** |

**工作量**: 1 天

---

### 8. Managed DB 手动时间戳

**表面改动**: 新方法 (~50 行)

**实际依赖**:

```
openManaged()
    ↓
禁用自动时间戳:
  - 用户手动指定 readTs/commitTs
    ↓
newTransactionAt(readTs, update)
    ↓
commitAt(commitTs, callback)
    ↓
newWriteBatchAt(commitTs)
```

**涉及文件**:

| 文件 | 改动内容 | 代码量 |
|------|----------|--------|
| `badger.cj` | `openManaged()`, `newTransactionAt()` | ~30 行 |
| `transaction.cj` | `commitAt()` | ~20 行 |
| `write_batch.cj` | `setEntryAt()`, `deleteAt()` | ~20 行 |
| 测试文件 | Managed DB 测试 | ~80 行 |
| **总计** | | **~150 行** |

**工作量**: 1-2 天

---

### 9. Backup/Load 备份恢复

**表面改动**: 新方法 (~100 行)

**实际依赖**:

```
Backup(w, since)
    ↓
Stream 遍历所有 key-value
    ↓
序列化为 protobuf 或 JSON
    ↓
写入 Writer
    ↓
Load(r, maxPendingWrites)
    ↓
反序列化
    ↓
批量写入（使用 WriteBatch）
```

**涉及文件**:

| 文件 | 改动内容 | 代码量 |
|------|----------|--------|
| `backup.cj` | 新模块 | ~150 行 |
| `badger.cj` | `backup()`, `load()` | ~20 行 |
| `kv_list.cj` | 序列化格式（与 Stream 共享） | - |
| 测试文件 | 备份恢复测试 | ~100 行 |
| **总计** | | **~270 行** |

**工作量**: 2-3 天

---

### 10. DB 信息查询 API

**表面改动**: 添加方法 (~50 行)

**实际依赖**:

```
isClosed()   ← 简单标志位
sync()       ← 刷盘操作
size()       ← 遍历文件统计
levels()     ← LevelsController.getLevelInfo()
tables()     ← 遍历所有 TableInfo
estimateSize() ← 估算前缀下的数据量
```

**涉及文件**:

| 文件 | 改动内容 | 代码量 |
|------|----------|--------|
| `badger.cj` | 添加方法 | ~50 行 |
| `levels.cj` | `getLevelInfo()`, `getTableInfo()` | ~50 行 |
| `level_handler.cj` | 添加信息收集方法 | ~30 行 |
| 测试文件 | 信息查询测试 | ~50 行 |
| **总计** | | **~180 行** |

**工作量**: 1 天

---

## 完整工作量汇总

### P0 - 核心功能完善

| 功能 | 代码量 | 工作量 | 依赖项 |
|------|--------|--------|--------|
| BadgerException 异常类 | ~50 行 | 0.5 天 | 无 |
| DB.open/close 异常 | ~20 行 | 0.5 天 | BadgerException |
| Entry withMeta/withTTL | ~290 行 | 2-3 天 | 见上文分析 |
| Item 完整 API | ~40-90 行 | 0.5-3 天 | 可选懒加载 |
| IteratorOptions 完整字段 | ~30 行 | 0.5 天 | 无 |
| **P0 总计** | **~430-490 行** | **4-7 天** | |

### P1 - 重要功能

| 功能 | 代码量 | 工作量 | 依赖项 |
|------|--------|--------|--------|
| WriteBatch 批量写入 | ~270 行 | 2-3 天 | Transaction |
| Config with* 链式方法 | ~250 行 | 1 天 | 无 |
| DB 信息查询 API | ~180 行 | 1 天 | 无 |
| Txn.setEntry/commitAt | ~50 行 | 0.5 天 | Entry |
| Iterator.validForPrefix | ~20 行 | 0.5 天 | 无 |
| **P1 总计** | **~770 行** | **5-6 天** | |

### P2 - 高级功能

| 功能 | 代码量 | 工作量 | 依赖项 |
|------|--------|--------|--------|
| Stream API | ~490 行 | 5-7 天 | Context, KVList |
| MergeOperator | ~190 行 | 2-3 天 | 定时任务 |
| Sequence | ~150 行 | 1-2 天 | 持久化 |
| Backup/Load | ~270 行 | 2-3 天 | WriteBatch, KVList |
| Managed DB | ~150 行 | 1-2 天 | 无 |
| **P2 总计** | **~1250 行** | **11-17 天** | |

### P3 - 企业功能

| 功能 | 代码量 | 工作量 | 备注 |
|------|--------|--------|------|
| 加密支持 | ~300 行 | 5-7 天 | 需要加密库 |
| 命名空间 | ~100 行 | 2-3 天 | key 前缀处理 |
| 分布式订阅 | ~500 行 | 7-10 天 | 需要网络库 |
| 监控指标 | ~200 行 | 2-3 天 | 需要指标库 |

---

## 功能依赖图

```
                    ┌─────────────┐
                    │   Entry     │
                    │ withMeta/   │
                    │ withTTL     │
                    └──────┬──────┘
                           │
         ┌─────────────────┼─────────────────┐
         ▼                 ▼                 ▼
   ┌───────────┐    ┌───────────┐    ┌───────────┐
   │ 写入路径   │    │ 读取路径   │    │   Item    │
   │ badger.cj │    │ get/iter  │    │   API     │
   └───────────┘    └───────────┘    └───────────┘
         │                 │
         ▼                 ▼
   ┌───────────┐    ┌───────────┐
   │  VLog GC  │    │Compaction │
   │ 过期丢弃  │    │ 过期过滤  │
   └───────────┘    └───────────┘

   ┌─────────────┐
   │ WriteBatch  │◄──────┐
   └──────┬──────┘       │
          │              │
          ▼              │
   ┌─────────────┐       │
   │ Transaction │───────┤
   └─────────────┘       │
                         │
   ┌─────────────┐       │
   │  Backup/    │───────┘
   │   Load      │
   └─────────────┘

   ┌─────────────┐
   │   Stream    │
   └──────┬──────┘
          │
          ▼
   ┌─────────────┐    ┌─────────────┐
   │   KVList    │    │   Context   │
   └─────────────┘    └─────────────┘
```

---

## 实施建议

### 分阶段实施

**阶段 1 (P0)**: 4-7 天
- 完成 Entry withMeta/withTTL（包含完整的写入/读取/GC/Compaction 路径）
- 完成 Item 基本方法
- 添加异常类

**阶段 2 (P1)**: 5-6 天
- WriteBatch 批量写入
- Config 链式配置
- DB 信息查询

**阶段 3 (P2)**: 11-17 天
- Stream API（最复杂，需要 Context 和 KVList）
- MergeOperator
- Sequence
- Backup/Load
- Managed DB

### 风险点

1. **Entry withTTL**: 改动面广，需要 5 个模块协调修改
2. **Stream API**: 需要并发机制和 Context，仓颉生态可能不完善
3. **懒加载 Item**: 影响迭代器设计，需要重构

### 测试策略

每个功能需要覆盖：
1. 单元测试：基本功能
2. 集成测试：多模块协作
3. 边界测试：过期时间、并发、大数据量
4. 回归测试：确保现有功能不受影响

---

## 总结

| 阶段 | 代码量 | 工作量 | API 对齐率 |
|------|--------|--------|-----------|
| P0 核心完善 | ~430-490 行 | 4-7 天 | 60% |
| P1 重要功能 | ~770 行 | 5-6 天 | 75% |
| P2 高级功能 | ~1250 行 | 11-17 天 | 90% |
| P3 企业功能 | ~1100 行 | 16-23 天 | 100% |
| **总计** | **~3550 行** | **36-53 天** | |

**建议**：
1. 优先完成 P0，确保核心功能正确
2. P1 满足大部分使用场景
3. P2/P3 根据实际需求逐步实施