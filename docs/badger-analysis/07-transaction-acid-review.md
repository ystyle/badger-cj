# 事务 ACID 特性评审报告

**评审日期：** 2026-04-01  
**评审版本：** badger-cj Phase 3  
**评审目标：** 事务系统 ACID 特性完整性分析  

---

## 1. 评审结论

| ACID 特性 | Go 版本状态 | 仓颉版本状态 | 差距等级 |
|-----------|-------------|--------------|----------|
| **原子性 (Atomicity)** | ✅ 完整实现 | ❌ 不完整 | **高** |
| **一致性 (Consistency)** | ✅ MVCC + 冲突检测 | ✅ 相同机制 | 无 |
| **隔离性 (Isolation)** | ✅ Snapshot Isolation | ✅ 相同机制 | 无 |
| **持久性 (Durability)** | ✅ WAL + SyncWrites | ❌ 不完整 | **高** |

**总体评估：** 仓颉版本事务系统实现了隔离性和一致性，但原子性和持久性存在重大缺陷，需要紧急修复。

---

## 2. 详细分析

### 2.1 原子性 (Atomicity)

#### Go 版本实现

Go 版本通过**事务标记机制**实现原子性：

```go
// value.go:44-45
bitTxn    byte = 1 << 6  // 标记事务条目
bitFinTxn byte = 1 << 7  // 标记事务结束

// txn.go:582-591 - 提交时写入结束标记
if keepTogether {
    e := &Entry{
        Key:   y.KeyWithTs(txnKey, commitTs),
        Value: []byte(strconv.FormatUint(commitTs, 10)),
        meta:  bitFinTxn,  // 提交确认
    }
    entries = append(entries, e)
}
```

**恢复逻辑** (`memtable.go:480-512`)：
- 遇到 `bitTxn` 标记的条目 → 暂存到缓冲区
- 遇到 `bitFinTxn` 标记 → 确认提交，将暂存条目写入 Skiplist
- 未遇到 `bitFinTxn` → 丢弃暂存条目（相当于自动回滚）

**关键特性**：
1. ✅ 崩溃时未完成事务自动丢弃
2. ✅ 已完成事务完整恢复
3. ✅ 无需显式回滚操作

#### 仓颉版本实现

**文件：** `src/db/transaction.cj`

```cj
// transaction.cj:133-161 - 当前提交流程
public func commit(): Unit {
    commitTs = oracle.newCommitTs(txnState)  // 获取时间戳
    
    let req = db.reqPool.get(commitTs)
    for (entry in writes) {
        req.addEntry(entry.key, entry.value, ...)  // 添加条目
    }
    
    db.writeCh.add(req)  // 放入写入队列
    req.wait()           // 等待完成 ← 问题：无 WAL 先写
    
    oracle.doneCommit(commitTs)
    committed = true
}
```

**缺失机制**：
1. ❌ 无 `bitTxn` / `bitFinTxn` 事务标记
2. ❌ 无 WAL 先写机制
3. ❌ 无崩溃恢复逻辑
4. ❌ 无自动回滚能力

**风险场景**：
```
崩溃时机                     数据状态                恢复后
─────────────────────────────────────────────────────────
事务提交前                    无数据写入              正常（无影响）
WAL写入后、MemTable前         WAL有数据               ❌ 数据丢失
MemTable部分写入后            部分数据可见            ❌ 数据不一致
事务标记未写入                Skiplist有数据          ❌ 无法识别事务边界
```

### 2.2 一致性 (Consistency)

#### 共同实现机制

**文件对比**：
- Go: `txn.go:128-151` (`oracle.hasConflict`)
- CJ: `src/db/oracle.cj:166-180` (`hasConflict`)

```cj
// oracle.cj:166-180
private func hasConflict(txn: TxnState): Bool {
    if (txn.reads.isEmpty()) {
        return false
    }
    
    for (committedTxn in committedTxns) {
        for (readKey in txn.reads) {
            if (committedTxn.conflictKeys.contains(readKey)) {
                return true  // 冲突检测
            }
        }
    }
    
    return false
}
```

**实现完整性**：✅ 两版本一致

### 2.3 隔离性 (Isolation)

#### 共同实现机制

**Snapshot Isolation 模型**：

```
┌─────────────────────────────────────────────────────────┐
│ 事务 T1 (readTs=100)                                     │
│   ├─ 读取 key="foo" → 看到 version ≤ 100 的值            │
│   ├─ 写入 key="bar" → 标记 commitTs=101                  │
│   └─ commit() → 检查是否有其他事务修改了 readKeys         │
└─────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────┐
│ 事务 T2 (readTs=100)                                     │
│   ├─ 读取 key="bar" → 看到 version ≤ 100 的值            │
│   ├─ 写入 key="foo" → 标记 commitTs=102                  │
│   └─ commit() → 冲突！T1 写入了 T2 读过的 key             │
└─────────────────────────────────────────────────────────┘
```

**实现完整性**：✅ 两版本一致

### 2.4 持久性 (Durability)

#### Go 版本实现

**WAL 集成** (`memtable.go:170-199`)：

```go
func (mt *memTable) Put(key []byte, value y.ValueStruct) error {
    entry := &Entry{Key: key, Value: value.Value, ...}
    
    // 1. 先写 WAL
    if mt.wal != nil {
        if err := mt.wal.writeEntry(mt.buf, entry, mt.opt); err != nil {
            return y.Wrapf(err, "cannot write entry to WAL file")
        }
    }
    
    // 2. 再写 Skiplist
    mt.sl.Put(key, value)
    
    return nil
}
```

**同步选项** (`options.go:370-380`)：

```go
// WithSyncWrites - 每次写入后 fsync
// 默认值：false（性能优先）
// 推荐值：true（严格持久性）
func (opt Options) WithSyncWrites(val bool) Options {
    opt.SyncWrites = val
    return opt
}
```

**实现完整性**：✅ WAL + SyncWrites + 崩溃恢复

#### 仓颉版本实现

**WAL 文件** (`src/db/wal.cj`)：存在但未集成到事务流程

**问题分析**：

```cj
// wal.cj:50-65 - WAL 写入方法存在
public func write(key: Array<Byte>, value: ValueStruct): Unit {
    let entry = LogEntry(key, value.encode())
    let encoded = entry.encode()
    
    let f = file ?? throw Exception("WAL file not open")
    f.write(encoded)  // ← 存在但未在事务中使用
}

// transaction.cj:133-161 - 事务提交未调用 WAL
public func commit(): Unit {
    // ❌ 缺失：wal.write() 调用
    db.writeCh.add(req)  // 直接写入 MemTable
}
```

**缺失机制**：
1. ❌ 事务提交时未写 WAL
2. ❌ 无 `SyncWrites` 配置选项
3. ❌ 启动时无 WAL 恢复逻辑

---

## 3. 改进方案

### 3.1 事务标记机制（优先级：P0）

**目标**：实现原子性保证

**代码修改**：

```cj
// src/db/types.cj - 新增事务标记
public const TxnMeta: Byte = 0x40      // bitTxn = 1 << 6
public const FinTxnMeta: Byte = 0x80   // bitFinTxn = 1 << 7

// src/db/transaction.cj - 修改提交逻辑
public func commit(): Unit {
    commitTs = oracle.newCommitTs(txnState)
    
    // 1. 先写 WAL（带 bitTxn 标记）
    for (entry in writes) {
        let e = Entry(entry.key, entry.value, 
                      meta: entry.meta | TxnMeta, ...)
        wal.write(e.key, e.value)  // ← 新增
    }
    
    // 2. 写入事务结束标记（bitFinTxn）
    let finEntry = Entry(txnKey, commitTs.toString(), 
                         meta: FinTxnMeta)
    wal.write(finEntry.key, finEntry.value)  // ← 新增
    
    // 3. 同步 WAL
    wal.flush()  // ← 新增
    
    // 4. 写入 MemTable
    db.writeCh.add(req)
    req.wait()
    
    oracle.doneCommit(commitTs)
}
```

**恢复逻辑** (`src/db/badger.cj`)：

```cj
public func open(): Unit {
    // 加载 MemTable 时从 WAL 恢复
    mt.replayFromWAL()  // ← 新增方法
    
    // 恢复逻辑：
    // - 遇到 bitTxn → 暂存条目
    // - 遇到 bitFinTxn → 确认提交，写入 Skiplist
    // - 无 bitFinTxn → 丢弃暂存条目
}
```

### 3.2 WAL 集成（优先级：P0）

**目标**：实现持久性保证

**文件修改**：

```cj
// src/db/config.cj - 新增配置
public class Config {
    public let syncWrites: Bool  // ← 新增
    
    public init(dir: String, syncWrites!: Bool = false) {
        this.syncWrites = syncWrites
    }
}

// src/db/wal.cj - 新增同步方法
public func sync(): Unit {
    if (syncWrites) {
        file.flush()  // fsync
    }
}
```

### 3.3 两阶段提交（优先级：P1）

**目标**：严格的原子性保证

**流程设计**：

```
Phase 1: Prepare
┌─────────────────────────────────────────────────────┐
│ 1. 写入 WAL（bitTxn 标记）                           │
│ 2. 同步 WAL（fsync）                                │
│ 3. 标记事务状态：PREPARED                            │
└─────────────────────────────────────────────────────┘

Phase 2: Commit
┌─────────────────────────────────────────────────────┐
│ 1. 写入 MemTable                                    │
│ 2. 写入 bitFinTxn 标记到 WAL                        │
│ 3. 标记事务状态：COMMITTED                           │
│ 4. 清理 WAL（异步）                                  │
└─────────────────────────────────────────────────────┘
```

### 3.4 单元测试（优先级：P0）

**新增测试用例**：

```cj
// tests/transaction_test.cj
@Test
func testAtomicityOnCrash(): Unit {
    // 模拟崩溃恢复
    let db = Badger.open(dir, syncWrites: true)
    
    let txn = db.newTransaction(true)
    txn.set("key1", "value1")
    txn.set("key2", "value2")
    
    // 写入 WAL 后模拟崩溃（不写入 bitFinTxn）
    wal.writeWithoutFinTxn(...)
    
    // 重启数据库
    db.close()
    let db2 = Badger.open(dir)
    
    // 验证：未完成事务被丢弃
    Assert(db2.get("key1").isNone())
    Assert(db2.get("key2").isNone())
}

@Test
func testDurabilityWithSyncWrites(): Unit {
    let db = Badger.open(dir, syncWrites: true)
    
    let txn = db.newTransaction(true)
    txn.set("key", "value")
    txn.commit()
    
    // 模拟崩溃
    db.crash()
    
    // 重启
    let db2 = Badger.open(dir)
    
    // 验证：数据持久化
    Assert(db2.get("key") == Some("value"))
}
```

---

## 4. 实施计划

### 4.1 Phase 3 补充任务

| 任务 | 工作量 | 优先级 | 负责模块 |
|------|--------|--------|----------|
| 添加事务标记常量 | 0.5 天 | P0 | `types.cj` |
| 修改事务提交流程 | 1 天 | P0 | `transaction.cj` |
| 实现 WAL 恢复逻辑 | 2 天 | P0 | `wal.cj`, `badger.cj` |
| 添加 SyncWrites 配置 | 0.5 天 | P0 | `config.cj` |
| 编写 ACID 单元测试 | 2 天 | P0 | `tests/` |
| **总计** | **5.5 天** | - | - |

### 4.2 验收标准

**原子性验收**：
- ✅ 崩溃恢复测试通过
- ✅ 未完成事务自动丢弃
- ✅ 已完成事务完整恢复

**持久性验收**：
- ✅ SyncWrites=true 时数据不丢失
- ✅ WAL 恢复测试通过

---

## 5. 风险评估

### 5.1 当前风险

| 风险 | 等级 | 影响 | 缓解措施 |
|------|------|------|----------|
| 数据丢失 | **高** | 用户数据不可恢复 | 紧急修复 WAL 集成 |
| 数据不一致 | **高** | 事务部分提交 | 紧急修复事务标记 |
| 性能下降 | 中 | SyncWrites=true 降低性能 | 提供配置选项 |

### 5.2 修复后风险

| 风险 | 等级 | 影响 | 缓解措施 |
|------|------|------|----------|
| WAL 空间增长 | 低 | 磁盘占用增加 | Compaction 时清理 |
| 恢复时间增加 | 低 | 启动变慢 | 限制 WAL 文件数量 |

---

## 6. 参考文献

### Go 版本关键文件

| 文件 | 行号 | 功能 |
|------|------|------|
| `value.go` | 44-45 | 事务标记定义 |
| `txn.go` | 582-591 | 提交时写入 bitFinTxn |
| `memtable.go` | 170-199 | WAL 先写机制 |
| `memtable.go` | 480-512 | 崩溃恢复逻辑 |
| `options.go` | 370-380 | SyncWrites 配置 |

### 仓颉版本关键文件

| 文件 | 行号 | 功能 |
|------|------|------|
| `transaction.cj` | 133-161 | 提交流程（需修改） |
| `oracle.cj` | 166-180 | 冲突检测（已完成） |
| `wal.cj` | 50-65 | WAL 写入（需集成） |

---

## 7. 结论

### 当前状态

仓颉版本事务系统**隔离性和一致性**已完整实现，达到生产级质量。

**原子性和持久性**存在重大缺陷，需要紧急修复。

### 改进后预期

修复后将达到 Go 版本同等 ACID 保证：

- ✅ 原子性：崩溃时未完成事务自动丢弃
- ✅ 一致性：MVCC + 冲突检测
- ✅ 隔离性：Snapshot Isolation
- ✅ 持久性：WAL + SyncWrites

### 建议优先级

1. **立即修复**（P0）：事务标记 + WAL 集成（5.5 天）
2. **后续优化**（P1）：两阶段提交、性能调优

---

**评审人：** AI Code Agent  
**评审日期：** 2026-04-01  
**下次评审：** Phase 4 事务增强完成后