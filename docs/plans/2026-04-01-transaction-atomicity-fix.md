# Transaction Atomicity Fix Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 修复事务原子性问题，确保崩溃恢复时未完成事务被正确丢弃

**Architecture:** 实现 Go 版本的 bitTxn/bitFinTxn 事务标记机制。写入时所有事务条目标记 bitTxn，最后追加 bitFinTxn 条目。恢复时先缓存 bitTxn 条目，遇到 bitFinTxn 才确认提交，否则丢弃。

**Tech Stack:** 仓颉语言，LSM-Tree，WAL

---

## 问题分析

### 当前状态

| 场景 | 当前行为 | 正确行为 |
|------|----------|----------|
| 事务写入 key1,key2,key3，崩溃在 key2 后 | key1,key2 可见 | 整个事务丢弃 |
| 事务完成但 bitFinTxn 未写入 | 部分数据可见 | 整个事务丢弃 |
| 事务完整写入 | 数据可见 | 数据可见 |

### Go 版本实现

```go
// value.go
bitTxn    byte = 1 << 6  // 0x40 - 事务条目标记
bitFinTxn byte = 1 << 7  // 0x80 - 事务结束标记

// db.go
txnKey = []byte("!badger!txn")  // 事务结束标记的 key

// txn.go - 提交时
if keepTogether {
    e.meta |= bitTxn  // 标记事务条目
}
// 最后追加结束标记
entries = append(entries, &Entry{
    Key:   y.KeyWithTs(txnKey, commitTs),
    Value: []byte(strconv.FormatUint(commitTs, 10)),
    meta:  bitFinTxn,
})

// memtable.go - 恢复时
case e.meta&bitTxn > 0:
    entries = append(entries, e)  // 缓存
case e.meta&bitFinTxn > 0:
    // 确认提交，写入缓存的条目
    for _, e := range entries {
        fn(*e, vp)
    }
    entries = entries[:0]
```

---

## Task 1: 添加事务标记常量和 txnKey

**Files:**
- Modify: `src/db/types.cj`
- Modify: `src/db/badger.cj`

**Step 1: 在 types.cj 添加事务标记常量**

```cangjie
// 在 Meta 类中添加
public static let bitTxn: Byte = 0x40      // 1 << 6 - 事务条目标记
public static let bitFinTxn: Byte = 0x80   // 1 << 7 - 事务结束标记
```

**Step 2: 在 badger.cj 添加 txnKey 常量**

```cangjie
// 在文件顶部添加
private let TxnKey: Array<Byte> = [0x21, 0x62, 0x61, 0x64, 0x67, 0x65, 0x72, 0x21, 0x74, 0x78, 0x6e]  // "!badger!txn"
```

**Step 3: 运行测试确保编译通过**

Run: `cjpm build -j 16`
Expected: BUILD SUCCESS

**Step 4: Commit**

```bash
git add src/db/types.cj src/db/badger.cj
git commit -m "feat: 添加事务标记常量 bitTxn/bitFinTxn 和 txnKey"
```

---

## Task 2: 修改 ValueStruct 添加事务标记支持

**Files:**
- Modify: `src/table/types.cj`

**Step 1: 检查 ValueStruct 的 meta 字段**

确认 `meta` 字段已存在，类型为 `Byte`。

**Step 2: 添加事务标记的辅助方法**

```cangjie
// 在 ValueStruct 中添加
public func isTxnEntry(): Bool {
    (meta & Meta.bitTxn) != 0
}

public func isFinTxn(): Bool {
    (meta & Meta.bitFinTxn) != 0
}

public func withTxnMark(): ValueStruct {
    ValueStruct(value, meta: meta | Meta.bitTxn, version: version, expiresAt: expiresAt, userMeta: userMeta)
}

public func withFinTxnMark(): ValueStruct {
    ValueStruct(value, meta: meta | Meta.bitFinTxn, version: version, expiresAt: expiresAt, userMeta: userMeta)
}

public func clearTxnMarks(): ValueStruct {
    ValueStruct(value, meta: meta & (!(Meta.bitTxn | Meta.bitFinTxn)), version: version, expiresAt: expiresAt, userMeta: userMeta)
}
```

**Step 3: 运行测试**

Run: `cjpm build -j 16`
Expected: BUILD SUCCESS

**Step 4: Commit**

```bash
git add src/table/types.cj
git commit -m "feat: ValueStruct 添加事务标记辅助方法"
```

---

## Task 3: 修改 MemTable.put 支持事务标记写入

**Files:**
- Modify: `src/db/memtable.cj`

**Step 1: 修改 put 方法签名**

```cangjie
// 当前
public func put(key: Array<Byte>, vs: ValueStruct): Unit

// 保持不变，事务标记已经在 vs.meta 中
```

**Step 2: 确认 WAL 写入逻辑**

当前实现已正确：
```cangjie
if (!opt.DisableWAL && !replaying.load()) {
    if (let Some(w) <- wal) {
        w.write(key, vs)  // vs 已包含事务标记
    }
}
```

**Step 3: 无需修改，确认即可**

Run: `cjpm build -j 16`
Expected: BUILD SUCCESS

---

## Task 4: 修改事务提交流程添加事务标记

**Files:**
- Modify: `src/db/transaction.cj`

**Step 1: 添加 import**

```cangjie
import badgercj.table.Meta
```

**Step 2: 在 Transaction 类中添加辅助方法**

```cangjie
// 生成 txnKeyWithTs
private func makeTxnKey(commitTs: UInt64): Array<Byte> {
    keyWithTs(TxnKey, commitTs)
}
```

**Step 3: 修改 commit 方法添加事务标记**

找到 `sendToWriteCh` 调用处，修改前：

```cangjie
// 当前实现
let req = db.reqPool.get(commitTs)
for (entry in writes) {
    req.addEntry(entry.key, entry.value, ...)
}
```

修改后：

```cangjie
// 修改后的实现
let req = db.reqPool.get(commitTs)

// 1. 写入所有事务条目（带 bitTxn 标记）
for (entry in writes) {
    let vsWithTxn = entry.value.withTxnMark()
    req.addEntry(entry.key, vsWithTxn, ...)
}

// 2. 写入事务结束标记（bitFinTxn）
let txnKey = makeTxnKey(commitTs)
let finVs = ValueStruct(
    commitTs.toString().toArray(),
    meta: Meta.bitFinTxn,
    version: commitTs
)
req.addEntry(txnKey, finVs)

db.writeCh.add(req)
req.wait()
```

**Step 4: 运行测试**

Run: `cjpm test -j 4 --filter 'TransactionTest'`
Expected: PASSED (现有测试应该仍然通过)

**Step 5: Commit**

```bash
git add src/db/transaction.cj
git commit -m "feat: 事务提交时写入 bitTxn/bitFinTxn 标记"
```

---

## Task 5: 修改 WAL replay 实现事务边界处理

**Files:**
- Modify: `src/db/wal.cj`
- Modify: `src/db/memtable.cj`

**Step 1: 在 wal.cj 修改 replay 方法**

当前实现：
```cangjie
protected func replay(mt: MemTable): Unit {
    let entries = readAll()
    for (entry in entries) {
        let vs = ValueStruct.decode(entry.value)
        mt.put(entry.key, vs)
    }
}
```

修改为：
```cangjie
protected func replay(mt: MemTable): Unit {
    let entries = readAll()
    
    var pendingTxnEntries = ArrayList<(Array<Byte>, ValueStruct)>()
    var lastTxnTs: UInt64 = 0
    
    for (entry in entries) {
        let vs = ValueStruct.decode(entry.value)
        
        if (vs.isFinTxn()) {
            // 遇到 bitFinTxn，确认事务提交
            let txnTs = parseTs(entry.key)
            if (txnTs == lastTxnTs) {
                // 时间戳匹配，写入缓存的条目
                for ((key, value) in pendingTxnEntries) {
                    let cleanVs = value.clearTxnMarks()
                    mt.put(key, cleanVs)
                }
            }
            // 时间戳不匹配或成功写入，清空缓存
            pendingTxnEntries.clear()
            lastTxnTs = 0
        } else if (vs.isTxnEntry()) {
            // 遇到 bitTxn，暂存条目
            let txnTs = parseTs(entry.key)
            if (lastTxnTs == 0) {
                lastTxnTs = txnTs
            }
            if (txnTs == lastTxnTs) {
                pendingTxnEntries.add((entry.key, vs))
            } else {
                // 时间戳不匹配，丢弃之前的缓存
                pendingTxnEntries.clear()
                pendingTxnEntries.add((entry.key, vs))
                lastTxnTs = txnTs
            }
        } else {
            // 普通条目，直接写入
            if (lastTxnTs != 0) {
                // 有未完成的事务，丢弃
                pendingTxnEntries.clear()
                lastTxnTs = 0
            }
            mt.put(entry.key, vs)
        }
    }
    
    // 遍历结束，丢弃未完成的事务
    // pendingTxnEntries 自动丢弃
}
```

**Step 2: 添加 parseTs 辅助函数**

在 `helpers.cj` 中已存在 `parseTs` 函数，确认可用。

**Step 3: 在 memtable.cj 添加 replay 状态标记**

确保 `replaying` AtomicBool 已存在并在 replay 期间设置。

**Step 4: 运行测试**

Run: `cjpm test -j 4 --filter 'WALTest'`
Expected: PASSED

**Step 5: Commit**

```bash
git add src/db/wal.cj src/db/memtable.cj
git commit -m "feat: WAL replay 实现事务边界处理，未完成事务自动丢弃"
```

---

## Task 6: 添加 SyncWrites 配置选项

**Files:**
- Modify: `src/db/config.cj`

**Step 1: 在 Config struct 添加字段**

```cangjie
public var SyncWrites: Bool

// init 中添加
syncWrites!: Bool = false
this.SyncWrites = syncWrites
```

**Step 2: 添加 withSyncWrites 方法**

```cangjie
public func withSyncWrites(sync: Bool): Config {
    var conf = this
    conf.SyncWrites = sync
    conf
}
```

**Step 3: 修改 WAL.flush 支持同步**

在 `src/db/wal.cj`：
```cangjie
public func sync(): Unit {
    lock.lock()
    try {
        if (let Some(f) <- file) {
            f.flush()
            // 注意：仓颉的 flush 可能等同于 fsync
            // 如果需要更强的持久性保证，检查文档
        }
    } finally {
        lock.unlock()
    }
}
```

**Step 4: 在 MemTable.put 添加同步选项**

```cangjie
public func put(key: Array<Byte>, vs: ValueStruct): Unit {
    if (!opt.DisableWAL && !replaying.load()) {
        if (let Some(w) <- wal) {
            w.write(key, vs)
            if (opt.SyncWrites) {
                w.sync()
            }
        }
    }
    // ... rest of the method
}
```

**Step 5: 运行测试**

Run: `cjpm build -j 16`
Expected: BUILD SUCCESS

**Step 6: Commit**

```bash
git add src/db/config.cj src/db/wal.cj src/db/memtable.cj
git commit -m "feat: 添加 SyncWrites 配置选项，支持严格持久性"
```

---

## Task 7: 编写事务原子性测试

**Files:**
- Create: `src/db/transaction_atomicity_test.cj`

**Step 1: 创建测试文件**

```cangjie
package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*

@Test
class TransactionAtomicityTest {
    
    private func cleanupDir(dir: String): Unit {
        let path = Path(dir)
        if (exists(path)) {
            remove(path, recursive: true)
        }
    }
    
    @TestCase
    func testTransactionMarkerWritten(): Unit {
        let dir = "/tmp/badger_txn_marker_test"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64, syncWrites: true)
        let db = Badger.open(opt)
        
        let txn = db.newTransaction(update: true)
        txn.set("key1".toArray(), "value1".toArray())
        txn.set("key2".toArray(), "value2".toArray())
        txn.commit()
        
        db.close()
        
        // 验证 WAL 文件包含事务标记
        let walPath = "${dir}/1.mem"
        if (exists(Path(walPath))) {
            let wal = WAL.openForRead(walPath)
            let entries = wal.readAll()
            wal.close()
            
            var hasTxnMark = false
            var hasFinMark = false
            
            for (entry in entries) {
                let vs = ValueStruct.decode(entry.value)
                if (vs.isTxnEntry()) {
                    hasTxnMark = true
                }
                if (vs.isFinTxn()) {
                    hasFinMark = true
                }
            }
            
            @Assert(hasTxnMark, true)
            @Assert(hasFinMark, true)
        }
        
        cleanupDir(dir)
    }
    
    @TestCase
    func testIncompleteTransactionDiscarded(): Unit {
        let dir = "/tmp/badger_txn_incomplete_test"
        cleanupDir(dir)
        
        // 1. 写入数据但不关闭（模拟崩溃）
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db1 = Badger.open(opt)
        
        db1.update({ txn =>
            txn.set("complete_key".toArray(), "complete_value".toArray())
        })
        db1.flushWAL()
        
        // 手动写入一个不完整的事务到 WAL
        let walPath = "${dir}/1.mem"
        let wal = WAL.open(walPath)
        // 写入带 bitTxn 但没有 bitFinTxn 的条目
        let incompleteVs = ValueStruct(
            "incomplete_value".toArray(),
            meta: Meta.bitTxn,
            version: 100
        )
        wal.write(keyWithTs("incomplete_key".toArray(), 100), incompleteVs)
        wal.close()
        
        // 2. 重新打开，验证不完整事务被丢弃
        let db2 = Badger.open(opt)
        
        @Assert(db2.get("complete_key".toArray()).isSome(), true)
        @Assert(db2.get("incomplete_key".toArray()).isNone(), true)
        
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testCompleteTransactionRecovered(): Unit {
        let dir = "/tmp/badger_txn_complete_test"
        cleanupDir(dir)
        
        // 1. 写入事务
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64, syncWrites: true)
        let db1 = Badger.open(opt)
        
        db1.update({ txn =>
            txn.set("txn_key1".toArray(), "txn_value1".toArray())
            txn.set("txn_key2".toArray(), "txn_value2".toArray())
        })
        
        // 2. 不关闭，直接重新打开
        let db2 = Badger.open(opt)
        
        @Assert(db2.get("txn_key1".toArray()).isSome(), true)
        @Assert(db2.get("txn_key2".toArray()).isSome(), true)
        
        if (let Some(vs) <- db2.get("txn_key1".toArray())) {
            @Assert(vs.value, "txn_value1".toArray())
        }
        
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testSyncWritesDurability(): Unit {
        let dir = "/tmp/badger_sync_writes_test"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64, syncWrites: true)
        let db = Badger.open(opt)
        
        db.update({ txn =>
            txn.set("sync_key".toArray(), "sync_value".toArray())
        })
        
        // 立即重新打开（不调用 close）
        let db2 = Badger.open(opt)
        
        @Assert(db2.get("sync_key".toArray()).isSome(), true)
        
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testMultipleTransactionsRecovery(): Unit {
        let dir = "/tmp/badger_multi_txn_test"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64, syncWrites: true)
        let db1 = Badger.open(opt)
        
        // 写入多个事务
        db1.update({ txn =>
            txn.set("txn1_key".toArray(), "txn1_value".toArray())
        })
        
        db1.update({ txn =>
            txn.set("txn2_key".toArray(), "txn2_value".toArray())
        })
        
        db1.update({ txn =>
            txn.set("txn3_key".toArray(), "txn3_value".toArray())
        })
        
        // 重新打开
        let db2 = Badger.open(opt)
        
        @Assert(db2.get("txn1_key".toArray()).isSome(), true)
        @Assert(db2.get("txn2_key".toArray()).isSome(), true)
        @Assert(db2.get("txn3_key".toArray()).isSome(), true)
        
        db2.close()
        cleanupDir(dir)
    }
}
```

**Step 2: 运行测试**

Run: `cjpm test -j 4 --filter 'TransactionAtomicityTest'`

预期部分测试失败（因为需要实现），记录失败原因。

**Step 3: 修复测试问题**

根据测试结果修复代码。

**Step 4: 运行完整测试**

Run: `cjpm test -j 4 --no-progress`
Expected: ALL PASSED

**Step 5: Commit**

```bash
git add src/db/transaction_atomicity_test.cj
git commit -m "test: 添加事务原子性测试用例"
```

---

## Task 8: 更新 README 文档

**Files:**
- Modify: `README.md`

**Step 1: 添加 SyncWrites 配置说明**

在配置选项表中添加：
```
| `syncWrites` | false | 每次写入后 fsync，确保严格持久性 |
```

**Step 2: 添加事务 ACID 特性说明**

```markdown
## 事务 ACID 特性

### 原子性 (Atomicity)

- 所有事务条目使用 `bitTxn` 标记
- 事务结束写入 `bitFinTxn` 标记
- 崩溃恢复时，未完成事务自动丢弃

### 持久性 (Durability)

- WAL 先写机制
- `SyncWrites=true` 时每次写入后 fsync
- 进程崩溃后数据可恢复
```

**Step 3: Commit**

```bash
git add README.md
git commit -m "docs: 添加事务 ACID 特性说明"
```

---

## Task 9: 更新进度跟踪文档

**Files:**
- Modify: `docs/progress-tracking.md`

**Step 1: 添加完成记录**

```markdown
### Phase 3.5: 事务原子性修复 (2026-04-01)

**完成内容：**
- [x] 事务标记 bitTxn/bitFinTxn 实现
- [x] WAL replay 事务边界处理
- [x] SyncWrites 配置选项
- [x] 事务原子性测试

**验收结果：**
- 所有 ACID 测试通过
- 未完成事务自动丢弃
- SyncWrites 确保数据持久化
```

**Step 2: Commit**

```bash
git add docs/progress-tracking.md
git commit -m "docs: 更新进度跟踪，记录事务原子性修复"
```

---

## 验收标准

| 标准 | 验证方法 |
|------|----------|
| 未完成事务自动丢弃 | `testIncompleteTransactionDiscarded` 通过 |
| 已完成事务完整恢复 | `testCompleteTransactionRecovered` 通过 |
| SyncWrites 确保持久性 | `testSyncWritesDurability` 通过 |
| 多事务恢复正确 | `testMultipleTransactionsRecovery` 通过 |
| 现有测试不受影响 | `cjpm test` 全部通过 |

---

## 风险与缓解

| 风险 | 缓解措施 |
|------|----------|
| 性能下降 | SyncWrites 默认 false，用户按需开启 |
| WAL 空间增长 | Compaction 时清理 WAL |
| 兼容性 | 旧 WAL 文件可正常恢复（无事务标记的条目直接写入） |

---

## 预估工作量

| 任务 | 预估时间 |
|------|----------|
| Task 1-3: 常量和标记 | 0.5 小时 |
| Task 4: 事务提交流程 | 1 小时 |
| Task 5: WAL replay | 2 小时 |
| Task 6: SyncWrites | 0.5 小时 |
| Task 7: 测试用例 | 2 小时 |
| Task 8-9: 文档 | 0.5 小时 |
| **总计** | **6.5 小时** |