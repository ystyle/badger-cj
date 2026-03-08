# Phase 4: 完整事务与 MVCC 设计文档

**项目名称：** badger-cj  
**阶段：** Phase 4 - 完整事务与 MVCC  
**日期：** 2026-03-08  
**状态：** 🚀 **Week 1-2 已完成，Week 3 进行中**

---

## 执行摘要

本文档定义 Phase 4 的完整设计，实现与 Go BadgerDB v4 兼容的事务系统，包括 Oracle（全局时间戳管理）、MVCC（多版本并发控制）、冲突检测、SSI（可串行化快照隔离）以及 Iterator/Snapshot 功能。

**核心特性：**
- ✅ Oracle - 全局时间戳管理器
- ✅ MVCC - 多版本并发控制
- ✅ SSI - 可串行化快照隔离
- ✅ 冲突检测 - 基于读写集合
- ✅ Iterator - 一致性范围扫描
- ✅ Snapshot - 一致性快照读
- ✅ 并发事务 - 支持多事务并发执行

**设计原则：**
- 兼容 Go BadgerDB v4 的事务语义
- 支持可串行化快照隔离（SSI）
- 高性能的冲突检测机制
- 一致性的 Iterator 和 Snapshot

---

## 1. 设计目标

### 1.1 功能目标

| 功能模块 | 目标 | 验收标准 |
|---------|------|---------|
| Oracle | 全局时间戳管理 | 时间戳单调递增，正确追踪读写标记 |
| MVCC | 多版本并发控制 | 同一 key 支持多版本，按时间戳读取 |
| 冲突检测 | SSI 隔离级别 | 并发事务冲突能正确检测和拒绝 |
| Transaction | 完整事务支持 | Begin/Commit/Rollback 正常工作 |
| Iterator | 一致性范围扫描 | 基于 readTs 的一致性读取 |
| Snapshot | 一致性快照 | 快照读不受后续写入影响 |

### 1.2 非功能目标

- **性能：** 单次 Get/Set 操作 < 1ms，1000 次事务提交 < 100ms
- **并发性：** 支持至少 100 个并发事务
- **正确性：** 冲突检测准确率 100%
- **兼容性：** 与 Go BadgerDB v4 语义兼容

### 1.3 范围边界

**包含（Phase 4）：**
- ✅ Oracle 全局时间戳管理
- ✅ WaterMark 追踪机制
- ✅ 完整事务实现（读集合、写集合追踪）
- ✅ 冲突检测算法
- ✅ Iterator 一致性读取
- ✅ Snapshot 快照功能
- ✅ 并发事务支持

**不包含（延后到 Phase 5）：**
- ❌ Managed DB（手动管理时间戳）
- ❌ Transaction View（回调式事务）
- ❌ Stream API（大规模数据处理）

---

## 2. 架构设计

### 2.1 整体架构

```
┌──────────────────────────────────────────────────┐
│                  Application                      │
└────────────┬─────────────────────────────────────┘
             │
     ┌───────▼────────┐
     │   Transaction  │  (完整版)
     │  - readTs      │
     │  - reads[]     │
     │  - writes[]    │
     │  - commitTs    │
     └───────┬────────┘
             │
     ┌───────▼────────────────────────────────────┐
     │              DB (API Layer)                │
     │  - open() / close()                        │
     │  - newTransaction() / view() / update()    │
     └───────┬────────────────────────────────────┘
             │
    ┌────────┼─────────┬──────────────┐
    │        │         │              │
┌───▼────┐ ┌─▼────┐ ┌──▼─────┐ ┌─────▼────┐
│Oracle  │ │Levels│ │VLog    │ │MemTable  │
│        │ │Ctrl  │ │Manager │ │+ WAL     │
└───┬────┘ └─┬────┘ └──┬─────┘ └────┬─────┘
    │        │         │            │
    │   ┌────▼────┐    │            │
    │   │  Level  │    │            │
    │   │ Handler │    │            │
    │   └────┬────┘    │            │
    │        │         │            │
    │   ┌────▼────┐    │            │
    │   │ Tables  │    │            │
    │   │(.sst)   │    │            │
    │   └────┬────┘    │            │
    │        │         │            │
    └────────┼─────────┼────────────┘
             │         │
        ┌────▼─────────▼────┐
        │   Compaction      │
        └───────────────────┘
```

### 2.2 事务流程

**事务提交流程：**
```
Transaction.begin()
    ↓
Oracle.readTs()  // 获取读时间戳
    ↓
... 读写操作 ...
    ↓
Transaction.commit()
    ↓
Oracle.newCommitTs(txn)
    ├─ 检查冲突 (hasConflict)
    │  ├─ 遍历 committedTxns
    │  └─ 检查 reads 和 writes 重叠
    ├─ 返回 commitTs 或冲突错误
    ↓
写入 MemTable (带 commitTs)
    ↓
Oracle.doneCommit(commitTs)
```

**冲突检测流程：**
```
hasConflict(txn)
    ↓
for committedTxn in committedTxns:
    if committedTxn.ts <= txn.readTs:
        continue  // 事务开始前已提交，无冲突
    
    for readKey in txn.reads:
        if readKey in committedTxn.conflictKeys:
            return true  // 读集合与写集合重叠，冲突！
    ↓
return false  // 无冲突
```

### 2.3 时间戳管理

**时间戳分配策略：**
```
nextTxnTs = 1  // 初始化

// 获取读时间戳
readTs():
    ts = nextTxnTs - 1
    readMark.Begin(ts)
    waitFor(txnMark >= ts)  // 等待之前的提交完成
    return ts

// 获取提交时间戳
newCommitTs(txn):
    if hasConflict(txn):
        return Error(Conflict)
    
    ts = nextTxnTs
    nextTxnTs++
    txnMark.Begin(ts)
    
    // 记录已提交事务
    committedTxns.append({
        ts: ts,
        conflictKeys: txn.conflictKeys
    })
    
    return ts

// 完成提交
doneCommit(commitTs):
    readMark.Done(txn.readTs)
    txnMark.Done(commitTs)
    
    // 清理旧的 committedTxns
    cleanupCommittedTransactions()
```

---

## 3. 模块设计

### 3.1 Oracle（全局时间戳管理器）

#### 3.1.1 职责

- 管理全局唯一的时间戳
- 追踪读写操作完成情况
- 存储已提交事务信息（用于冲突检测）
- 提供冲突检测接口

#### 3.1.2 核心接口

**文件：** `src/db/oracle.cj`, `src/db/oracle_test.cj`

```cangjie
class Oracle {
    private let isManaged: Bool
    private let detectConflicts: Bool
    
    private let lock: Mutex
    private let writeChLock: Mutex
    private var nextTxnTs: UInt64
    
    // 追踪标记
    private let txnMark: WaterMark   // 追踪提交完成
    private let readMark: WaterMark  // 追踪读取完成
    
    // 已提交事务（用于冲突检测）
    private var committedTxns: ArrayList<CommittedTxn>
    private var lastCleanupTs: UInt64
    
    private let closer: Closer
    
    // 初始化
    public init(opt: DBOptions) {
        isManaged = opt.managedTxns
        detectConflicts = opt.detectConflicts
        
        nextTxnTs = 1  // 从 1 开始
        txnMark = WaterMark("badger.TxnTimestamp")
        readMark = WaterMark("badger.PendingReads")
        committedTxns = ArrayList<CommittedTxn>()
        
        txnMark.init(closer)
        readMark.init(closer)
    }
    
    // 获取读时间戳
    public func readTs(): UInt64 {
        if (isManaged) {
            throw IllegalStateException("ReadTs should not be called for managed DB")
        }
        
        synchronized (lock) {
            let ts = nextTxnTs - 1
            readMark.begin(ts)
        }
        
        // 等待之前的提交完成
        txnMark.waitForMark(ts)
        
        return ts
    }
    
    // 获取下一个时间戳
    public func nextTs(): UInt64 {
        synchronized (lock) {
            return nextTxnTs
        }
    }
    
    // 获取提交时间戳（带冲突检测）
    public func newCommitTs(txn: Transaction): Result<UInt64, TxnConflict> {
        synchronized (lock) {
            // 冲突检测
            if (hasConflict(txn)) {
                return Err(TxnConflict())
            }
            
            if (!isManaged) {
                doneRead(txn)
                cleanupCommittedTransactions()
                
                let ts = nextTxnTs
                nextTxnTs++
                txnMark.begin(ts)
                
                // 记录已提交事务
                if (detectConflicts) {
                    committedTxns.add(CommittedTxn(
                        ts: ts,
                        conflictKeys: txn.conflictKeys
                    ))
                }
                
                return Ok(ts)
            } else {
                // Managed 模式：使用事务指定的时间戳
                return Ok(txn.commitTs)
            }
        }
    }
    
    // 完成读取
    public func doneRead(txn: Transaction): Unit {
        if (!txn.doneRead) {
            txn.doneRead = true
            readMark.done(txn.readTs)
        }
    }
    
    // 完成提交
    public func doneCommit(commitTs: UInt64): Unit {
        if (!isManaged) {
            txnMark.done(commitTs)
        }
    }
    
    // 冲突检测（必须在 lock 内调用）
    private func hasConflict(txn: Transaction): Bool {
        if (txn.reads.isEmpty()) {
            return false
        }
        
        for (committedTxn in committedTxns) {
            // 已提交事务的时间戳 <= 读时间戳，无冲突
            if (committedTxn.ts <= txn.readTs) {
                continue
            }
            
            // 检查读集合是否与写集合重叠
            for (readKey in txn.reads) {
                if (committedTxn.conflictKeys.contains(readKey)) {
                    return true  // 冲突！
                }
            }
        }
        
        return false
    }
    
    // 清理已提交事务记录
    private func cleanupCommittedTransactions(): Unit {
        if (!detectConflicts) {
            return
        }
        
        let maxReadTs = isManaged ? discardTs : readMark.doneUntil()
        
        if (maxReadTs == lastCleanupTs) {
            return
        }
        lastCleanupTs = maxReadTs
        
        // 移除 ts <= maxReadTs 的事务
        let newCommittedTxns = ArrayList<CommittedTxn>()
        for (txn in committedTxns) {
            if (txn.ts > maxReadTs) {
                newCommittedTxns.add(txn)
            }
        }
        committedTxns = newCommittedTxns
    }
    
    // 停止
    public func stop(): Unit {
        closer.signalAndWait()
    }
}

// 已提交事务记录
struct CommittedTxn {
    let ts: UInt64
    let conflictKeys: HashSet<UInt64>  // key fingerprint
}

// 冲突错误
public class TxnConflict <: Exception {
    public init() {
        super("Transaction conflict detected")
    }
}
```

#### 3.1.3 测试用例

```cangjie
@Test
func testOracleReadTs() {
    let oracle = Oracle(DBOptions())
    
    let ts1 = oracle.readTs()
    let ts2 = oracle.readTs()
    
    Assert.isTrue(ts1 >= 0)
    Assert.isTrue(ts2 >= ts1)
    
    oracle.stop()
}

@Test
func testOracleNewCommitTs() {
    let oracle = Oracle(DBOptions())
    
    let txn = Transaction(db)
    txn.set("key1".toArray(), "value1".toArray())
    
    let result = oracle.newCommitTs(txn)
    Assert.isTrue(result.isOk())
    
    let commitTs = result.unwrap()
    Assert.isTrue(commitTs > 0)
    
    oracle.stop()
}

@Test
func testOracleConflictDetection() {
    let oracle = Oracle(DBOptions())
    
    // 事务 1：读取 key1
    let txn1 = Transaction(db)
    txn1.get("key1".toArray())
    let readTs1 = txn1.readTs
    
    // 事务 2：写入 key1 并提交
    let txn2 = Transaction(db)
    txn2.set("key1".toArray(), "value2".toArray())
    let commitTs2 = oracle.newCommitTs(txn2).unwrap()
    oracle.doneCommit(commitTs2)
    
    // 事务 1 尝试提交（应该冲突）
    let result = oracle.newCommitTs(txn1)
    Assert.isTrue(result.isErr())
    
    oracle.stop()
}

@Test
func testOracleNoConflict() {
    let oracle = Oracle(DBOptions())
    
    // 事务 1：读取 key1
    let txn1 = Transaction(db)
    txn1.get("key1".toArray())
    
    // 事务 2：写入 key2（不同的 key）
    let txn2 = Transaction(db)
    txn2.set("key2".toArray(), "value2".toArray())
    let commitTs2 = oracle.newCommitTs(txn2).unwrap()
    oracle.doneCommit(commitTs2)
    
    // 事务 1 应该无冲突
    let result = oracle.newCommitTs(txn1)
    Assert.isTrue(result.isOk())
    
    oracle.stop()
}
```

---

### 3.2 WaterMark（完成标记追踪）

#### 3.2.1 职责

- 追踪操作的完成情况
- 支持等待特定索引完成
- 提供完成进度查询

#### 3.2.2 核心接口

**文件：** `src/db/watermark.cj`, `src/db/watermark_test.cj`

```cangjie
class WaterMark {
    private let doneUntil: AtomicUInt64
    private let lastIndex: AtomicUInt64
    private let name: String
    private let markCh: Channel<Mark>
    
    // 初始化
    public init(name: String) {
        this.name = name
        doneUntil = AtomicUInt64(0)
        lastIndex = AtomicUInt64(0)
        markCh = Channel<Mark>(100)
    }
    
    // 启动处理协程
    public func start(closer: Closer): Unit {
        spawn {
            process(closer)
        }
    }
    
    // 标记开始
    public func begin(index: UInt64): Unit {
        lastIndex.store(index)
        markCh.send(Mark(index: index, done: false))
    }
    
    // 标记完成
    public func done(index: UInt64): Unit {
        markCh.send(Mark(index: index, done: true))
    }
    
    // 获取完成进度
    public func doneUntil(): UInt64 {
        return doneUntil.load()
    }
    
    // 获取最后索引
    public func lastIndex(): UInt64 {
        return lastIndex.load()
    }
    
    // 等待标记完成
    public func waitForMark(index: UInt64): Unit {
        if (doneUntil.load() >= index) {
            return
        }
        
        let waitCh = Channel<Unit>(1)
        markCh.send(Mark(index: index, waiter: waitCh))
        
        waitCh.receive()
    }
    
    // 处理标记
    private func process(closer: Closer): Unit {
        let indices = MinHeap<UInt64>()
        let pending = HashMap<UInt64, Int>()
        let waiters = HashMap<UInt64, ArrayList<Channel<Unit>>>()
        
        while (!closer.isClosed()) {
            let mark = markCh.receive()
            
            if (mark.waiter != null) {
                // 等待请求
                let currentDone = doneUntil.load()
                if (currentDone >= mark.index) {
                    mark.waiter.send(())
                } else {
                    if (!waiters.contains(mark.index)) {
                        waiters[mark.index] = ArrayList<Channel<Unit>>()
                    }
                    waiters[mark.index].add(mark.waiter)
                }
            } else {
                // 处理 begin/done
                processOne(mark.index, mark.done, indices, pending)
                
                // 更新 doneUntil
                let currentDone = doneUntil.load()
                var until = currentDone
                
                while (!indices.isEmpty()) {
                    let min = indices.peek()
                    if (pending[min] > 0) {
                        break
                    }
                    indices.pop()
                    pending.remove(min)
                    until = min
                }
                
                if (until != currentDone) {
                    doneUntil.compareAndSwap(currentDone, until)
                }
                
                // 通知等待者
                notifyWaiters(currentDone, until, waiters)
            }
        }
    }
    
    private func processOne(
        index: UInt64,
        done: Bool,
        indices: MinHeap<UInt64>,
        pending: HashMap<UInt64, Int>
    ): Unit {
        let prev = pending.getOrDefault(index, 0)
        if (prev == 0) {
            indices.push(index)
        }
        
        let delta = done ? -1 : 1
        pending[index] = prev + delta
    }
    
    private func notifyWaiters(
        from: UInt64,
        to: UInt64,
        waiters: HashMap<UInt64, ArrayList<Channel<Unit>>>
    ): Unit {
        for (i in from + 1..to + 1) {
            if (waiters.contains(i)) {
                for (ch in waiters[i]) {
                    ch.send(())
                }
                waiters.remove(i)
            }
        }
    }
}

struct Mark {
    let index: UInt64
    let done: Bool
    let waiter: ?Channel<Unit>
}
```

#### 3.2.3 测试用例

```cangjie
@Test
func testWaterMarkBasic() {
    let wm = WaterMark("test")
    let closer = Closer()
    wm.start(closer)
    
    wm.begin(1)
    Assert.equal(1, wm.lastIndex())
    Assert.equal(0, wm.doneUntil())
    
    wm.done(1)
    sleep(100)  // 等待处理
    Assert.equal(1, wm.doneUntil())
    
    closer.close()
}

@Test
func testWaterMarkWaitForMark() {
    let wm = WaterMark("test")
    let closer = Closer()
    wm.start(closer)
    
    wm.begin(1)
    wm.begin(2)
    
    // 在另一个协程中完成
    spawn {
        sleep(100)
        wm.done(1)
        wm.done(2)
    }
    
    // 等待完成
    wm.waitForMark(2)
    Assert.equal(2, wm.doneUntil())
    
    closer.close()
}

@Test
func testWaterMarkMultipleBeginDone() {
    let wm = WaterMark("test")
    let closer = Closer()
    wm.start(closer)
    
    // 同一索引多次 begin/done
    wm.begin(1)
    wm.begin(1)
    wm.done(1)
    wm.done(1)
    
    sleep(100)
    Assert.equal(1, wm.doneUntil())
    
    closer.close()
}
```

---

### 3.3 Transaction（完整事务）

#### 3.3.1 职责

- 提供完整的事务 API
- 追踪读集合和写集合
- 支持冲突检测
- 提交和回滚

#### 3.3.2 核心接口

**文件：** `src/db/transaction.cj`, `src/db/transaction_test.cj`

```cangjie
public class Transaction {
    private let db: DB
    private let update: Bool  // 是否为更新事务
    
    let readTs: UInt64  // 读时间戳（包可见）
    private var commitTs: UInt64  // 提交时间戳（Managed 模式）
    
    // 读集合（key fingerprints）
    let reads: ArrayList<UInt64>
    private let readsLock: Mutex
    
    // 写集合（key fingerprints）
    let conflictKeys: HashSet<UInt64>
    
    // 本地写缓冲区
    private let pendingWrites: HashMap<Array<Byte>, Entry>
    private let duplicateWrites: ArrayList<Entry>
    
    private var size: Int64
    private var count: Int64
    private var discarded: Bool
    private var doneRead: Bool
    private let numIterators: AtomicInt32
    
    // 初始化
    public init(db: DB, update: Bool) {
        this.db = db
        this.update = update
        this.readTs = db.oracle.readTs()
        
        reads = ArrayList<UInt64>()
        readsLock = Mutex()
        
        if (update && db.opt.detectConflicts) {
            conflictKeys = HashSet<UInt64>()
        } else {
            conflictKeys = HashSet<UInt64>()  // 空集合
        }
        
        pendingWrites = HashMap<Array<Byte>, Entry>()
        duplicateWrites = ArrayList<Entry>()
        
        size = 0
        count = 1  // 预留一个给事务标记
        discarded = false
        doneRead = false
        numIterators = AtomicInt32(0)
    }
    
    // Get
    public func get(key: Array<Byte>): ?Item {
        if (key.isEmpty()) {
            throw ErrEmptyKey
        }
        if (discarded) {
            throw ErrDiscardedTxn
        }
        
        // 1. 查本地写缓冲区
        if (update && pendingWrites.contains(key)) {
            let entry = pendingWrites[key]
            if (entry.isDeletedOrExpired()) {
                return None
            }
            return Some(Item(
                key: key,
                value: entry.value,
                version: readTs,
                meta: entry.meta
            ))
        }
        
        // 2. 记录读（用于冲突检测）
        addReadKey(key)
        
        // 3. 从 DB 读取
        let seek = keyWithTs(key, readTs)
        let vs = db.get(seek)
        
        if (vs.value.isEmpty() && vs.meta == 0) {
            return None
        }
        if (isDeletedOrExpired(vs.meta, vs.expiresAt)) {
            return None
        }
        
        return Some(Item(
            key: key,
            value: vs.value,
            version: vs.version,
            meta: vs.meta,
            userMeta: vs.userMeta,
            expiresAt: vs.expiresAt
        ))
    }
    
    // Set
    public func set(key: Array<Byte>, value: Array<Byte>): Unit {
        setEntry(Entry(key: key, value: value))
    }
    
    // SetEntry
    public func setEntry(entry: Entry): Unit {
        modify(entry)
    }
    
    // Delete
    public func delete(key: Array<Byte>): Unit {
        let entry = Entry(
            key: key,
            value: [],
            meta: MetaDelete
        )
        modify(entry)
    }
    
    // 内部：修改操作
    private func modify(entry: Entry): Unit {
        // 验证
        if (!update) {
            throw ErrReadOnlyTxn
        }
        if (discarded) {
            throw ErrDiscardedTxn
        }
        if (entry.key.isEmpty()) {
            throw ErrEmptyKey
        }
        if (entry.key.size > 65000) {
            throw ErrKeyTooLarge
        }
        
        // 检查大小
        checkSize(entry)
        
        // 记录冲突键
        if (db.opt.detectConflicts) {
            let fp = memHash(entry.key)
            conflictKeys.add(fp)
        }
        
        // 处理重复写入（Managed 模式）
        if (pendingWrites.contains(entry.key)) {
            let oldEntry = pendingWrites[entry.key]
            if (oldEntry.version != entry.version) {
                duplicateWrites.add(oldEntry)
            }
        }
        
        pendingWrites[entry.key] = entry
    }
    
    // 记录读键
    func addReadKey(key: Array<Byte>): Unit {
        if (update) {
            let fp = memHash(key)
            
            readsLock.lock()
            reads.add(fp)
            readsLock.unlock()
        }
    }
    
    // Commit
    public func commit(): Unit {
        // 无写入，直接返回
        if (pendingWrites.isEmpty()) {
            discard()
            return
        }
        
        if (discarded) {
            throw ErrDiscardedTxn
        }
        
        defer {
            discard()
        }
        
        // 提交并发送
        let callback = commitAndSend()
        if (callback != null) {
            callback()
        }
    }
    
    // 提交并发送
    private func commitAndSend(): ?func(): Unit {
        let oracle = db.oracle
        
        // 获取提交时间戳（顺序很重要！）
        oracle.writeChLock.lock()
        defer {
            oracle.writeChLock.unlock()
        }
        
        let result = oracle.newCommitTs(this)
        if (result.isErr()) {
            throw ErrConflict
        }
        
        let commitTs = result.unwrap()
        
        // 设置版本号
        var keepTogether = true
        for (entry in pendingWrites.values()) {
            if (entry.version == 0) {
                entry.version = commitTs
            } else {
                keepTogether = false
            }
        }
        for (entry in duplicateWrites) {
            if (entry.version == 0) {
                entry.version = commitTs
            } else {
                keepTogether = false
            }
        }
        
        // 构造 entries
        let entries = ArrayList<Entry>()
        
        for (entry in pendingWrites.values()) {
            entry.key = keyWithTs(entry.key, entry.version)
            if (keepTogether) {
                entry.meta |= MetaTxn
            }
            entries.add(entry)
        }
        
        for (entry in duplicateWrites) {
            entry.key = keyWithTs(entry.key, entry.version)
            if (keepTogether) {
                entry.meta |= MetaTxn
            }
            entries.add(entry)
        }
        
        // 添加事务结束标记
        if (keepTogether) {
            entries.add(Entry(
                key: keyWithTs(txnKey, commitTs),
                value: commitTs.toString().toArray(),
                meta: MetaFinTxn
            ))
        }
        
        // 发送到写通道
        let request = db.sendToWriteCh(entries)
        
        // 返回回调
        return func(): Unit {
            request.wait()
            oracle.doneCommit(commitTs)
        }
    }
    
    // Discard
    public func discard(): Unit {
        if (discarded) {
            return
        }
        
        if (numIterators.load() > 0) {
            panic("Unclosed iterator at time of Txn.Discard.")
        }
        
        discarded = true
        
        if (!db.oracle.isManaged) {
            db.oracle.doneRead(this)
        }
    }
    
    // 创建迭代器
    public func newIterator(opt: IteratorOptions): Iterator {
        if (discarded) {
            panic(ErrDiscardedTxn)
        }
        if (db.isClosed()) {
            panic(ErrDBClosed)
        }
        
        numIterators.add(1)
        
        return Iterator(txn: this, opt: opt)
    }
    
    // 读取时间戳
    public func readTs(): UInt64 {
        return readTs
    }
    
    // 检查大小
    private func checkSize(entry: Entry): Unit {
        count += 1
        size += entry.estimateSize() + 10  // 10 bytes for version
        
        if (count >= db.opt.maxBatchCount || size >= db.opt.maxBatchSize) {
            throw ErrTxnTooBig
        }
    }
}
```

#### 3.3.3 DB 扩展

**文件：** `src/db/db.cj`

```cangjie
public class DB {
    // ... 已有字段 ...
    let oracle: Oracle  // 新增：Oracle
    
    // View（只读事务）
    public func view(fn: func(txn: Transaction): ?Exception): ?Exception {
        if (isClosed()) {
            return ErrDBClosed
        }
        
        let txn = newTransaction(update: false)
        defer {
            txn.discard()
        }
        
        return fn(txn)
    }
    
    // Update（读写事务）
    public func update(fn: func(txn: Transaction): ?Exception): ?Exception {
        if (isClosed()) {
            return ErrDBClosed
        }
        
        let txn = newTransaction(update: true)
        defer {
            txn.discard()
        }
        
        let err = fn(txn)
        if (err != null) {
            return err
        }
        
        return txn.commit()
    }
    
    // NewTransaction
    public func newTransaction(update: Bool): Transaction {
        if (opt.readOnly && update) {
            update = false
        }
        
        return Transaction(db: this, update: update)
    }
}
```

#### 3.3.4 测试用例

```cangjie
@Test
func testTransactionBasic() {
    let db = openTestDB()
    defer { db.close() }
    
    let txn = db.newTransaction(update: true)
    txn.set("key1".toArray(), "value1".toArray())
    txn.commit()
    
    let txn2 = db.newTransaction(update: false)
    let item = txn2.get("key1".toArray())
    Assert.isTrue(item.isSome())
    Assert.equal("value1", item.unwrap().value.toString())
}

@Test
func testTransactionRollback() {
    let db = openTestDB()
    defer { db.close() }
    
    db.set("key1".toArray(), "original".toArray())
    
    let txn = db.newTransaction(update: true)
    txn.set("key1".toArray(), "modified".toArray())
    txn.discard()  // 回滚
    
    let item = db.get("key1".toArray())
    Assert.equal("original", item.unwrap().toString())
}

@Test
func testTransactionConflict() {
    let db = openTestDB(DetectConflicts: true)
    defer { db.close() }
    
    // 事务 1：读取 key1
    let txn1 = db.newTransaction(update: true)
    txn1.get("key1".toArray())
    
    // 事务 2：写入 key1 并提交
    let txn2 = db.newTransaction(update: true)
    txn2.set("key1".toArray(), "value2".toArray())
    txn2.commit()
    
    // 事务 1 尝试写入并提交（应该冲突）
    txn1.set("key1".toArray(), "value1".toArray())
    let err = txn1.commit()
    Assert.isTrue(err.isErr())
    Assert.isTrue(err.unwrap() is TxnConflict)
}

@Test
func testTransactionNoConflict() {
    let db = openTestDB(DetectConflicts: true)
    defer { db.close() }
    
    // 事务 1：读取 key1
    let txn1 = db.newTransaction(update: true)
    txn1.get("key1".toArray())
    
    // 事务 2：写入 key2（不同的 key）
    let txn2 = db.newTransaction(update: true)
    txn2.set("key2".toArray(), "value2".toArray())
    txn2.commit()
    
    // 事务 1 应该无冲突
    txn1.set("key1".toArray(), "value1".toArray())
    let err = txn1.commit()
    Assert.isTrue(err.isOk())
}

@Test
func testTransactionView() {
    let db = openTestDB()
    defer { db.close() }
    
    db.set("key1".toArray(), "value1".toArray())
    
    let err = db.view(func(txn: Transaction): ?Exception {
        let item = txn.get("key1".toArray())
        Assert.equal("value1", item.unwrap().value.toString())
        return null
    })
    
    Assert.isTrue(err == null)
}

@Test
func testTransactionUpdate() {
    let db = openTestDB()
    defer { db.close() }
    
    let err = db.update(func(txn: Transaction): ?Exception {
        txn.set("key1".toArray(), "value1".toArray())
        return null
    })
    
    Assert.isTrue(err == null)
    
    let item = db.get("key1".toArray())
    Assert.equal("value1", item.unwrap().toString())
}

@Test
func testTransactionIsolation() {
    let db = openTestDB()
    defer { db.close() }
    
    // 事务 1：写入但未提交
    let txn1 = db.newTransaction(update: true)
    txn1.set("key1".toArray(), "value1".toArray())
    
    // 事务 2：应该看不到未提交的数据
    let txn2 = db.newTransaction(update: false)
    let item = txn2.get("key1".toArray())
    Assert.isTrue(item.isNone())
    
    // 事务 1 提交
    txn1.commit()
    
    // 事务 2 还是看不到（因为 readTs 在提交前）
    let item2 = txn2.get("key1".toArray())
    Assert.isTrue(item2.isNone())
    
    // 新事务应该能看到
    let txn3 = db.newTransaction(update: false)
    let item3 = txn3.get("key1".toArray())
    Assert.isTrue(item3.isSome())
}
```

---

### 3.4 Iterator（一致性迭代器）

#### 3.4.1 职责

- 提供一致性范围扫描
- 基于 readTs 读取数据
- 支持前向/反向迭代
- 支持预取优化

#### 3.4.2 核心接口

**文件：** `src/db/iterator.cj`, `src/db/iterator_test.cj`

```cangjie
public class Iterator {
    private let txn: Transaction
    private let readTs: UInt64
    private let opt: IteratorOptions
    
    private let iitr: MergeIterator  // 底层合并迭代器
    
    private var item: ?Item
    private let data: List<Item>     // 预取队列
    private let waste: List<Item>    // 废弃队列
    
    private var lastKey: Array<Byte>
    private var closed: Bool
    private var scanned: Int64
    
    // 初始化（由 Transaction 创建）
    init(txn: Transaction, opt: IteratorOptions) {
        this.txn = txn
        this.readTs = txn.readTs
        this.opt = opt
        
        // 构造迭代器链
        let iters = ArrayList<Iterator>()
        
        // 1. 添加 pending writes 迭代器
        if (txn.update) {
            let pwIter = newPendingWritesIterator(txn, opt.reverse)
            if (pwIter != null) {
                iters.add(pwIter)
            }
        }
        
        // 2. 添加 MemTable 迭代器
        let tables = db.getMemTables()
        for (table in tables) {
            iters.add(table.iterator(opt.reverse))
        }
        
        // 3. 添加 SSTable 迭代器
        db.lc.appendIterators(iters, opt)
        
        // 合并迭代器
        iitr = MergeIterator(iters, opt.reverse)
        
        data = List<Item>()
        waste = List<Item>()
        lastKey = []
        closed = false
        scanned = 0
    }
    
    // Item
    public func item(): ?Item {
        if (item == null) {
            return None
        }
        
        // 记录读（用于冲突检测）
        txn.addReadKey(item.unwrap().key)
        
        return item
    }
    
    // Valid
    public func valid(): Bool {
        if (item == null) {
            return false
        }
        
        // 检查前缀
        if (opt.prefix.size > 0) {
            return item.unwrap().key.startsWith(opt.prefix)
        }
        
        return true
    }
    
    // ValidForPrefix
    public func validForPrefix(prefix: Array<Byte>): Bool {
        return valid() && item.unwrap().key.startsWith(prefix)
    }
    
    // Next
    public func next(): Unit {
        if (iitr == null) {
            return
        }
        
        // 等待当前 item 完成
        item.unwrap().wait()
        scanned += item.unwrap().estimateSize()
        waste.push(item)
        
        // 获取下一个
        item = data.pop()
        
        while (iitr.valid() && hasPrefix()) {
            if (parseItem()) {
                break
            }
        }
    }
    
    // Seek
    public func seek(key: Array<Byte>): Unit {
        if (iitr == null) {
            return
        }
        
        if (!key.isEmpty()) {
            txn.addReadKey(key)
        }
        
        // 清空预取队列
        for (i in data.pop(); i != null; i = data.pop()) {
            i.wait()
            waste.push(i)
        }
        
        lastKey = []
        
        if (key.isEmpty()) {
            key = opt.prefix
        }
        
        if (key.isEmpty()) {
            iitr.rewind()
            prefetch()
            return
        }
        
        // Seek 到指定 key
        let seekKey = opt.reverse 
            ? keyWithTs(key, 0)
            : keyWithTs(key, readTs)
        
        iitr.seek(seekKey)
        prefetch()
    }
    
    // Rewind
    public func rewind(): Unit {
        seek([])
    }
    
    // Close
    public func close(): Unit {
        if (closed) {
            return
        }
        closed = true
        
        if (iitr == null) {
            txn.numIterators.sub(1)
            return
        }
        
        iitr.close()
        
        // 等待预取完成
        func waitFor(l: List<Item>): Unit {
            var item = l.pop()
            while (item != null) {
                item.wait()
                item = l.pop()
            }
        }
        
        waitFor(waste)
        waitFor(data)
        
        db.vlog.decrIteratorCount()
        txn.numIterators.sub(1)
    }
    
    // 解析 item
    private func parseItem(): Bool {
        let key = iitr.key()
        
        // 跳过内部 key
        if (!opt.internalAccess && key.startsWith(badgerPrefix)) {
            iitr.next()
            return false
        }
        
        // 跳过超出 readTs 的版本
        let version = parseTs(key)
        if (version > readTs || (opt.sinceTs > 0 && version <= opt.sinceTs)) {
            iitr.next()
            return false
        }
        
        // 跳过 banned key
        if (!key.startsWith(badgerPrefix) && db.isBanned(key) != null) {
            iitr.next()
            return false
        }
        
        // 返回所有版本
        if (opt.allVersions) {
            let newItem = newItem()
            fill(newItem)
            setItem(newItem)
            iitr.next()
            return true
        }
        
        // 前向迭代：跳过相同 key 的旧版本
        if (!opt.reverse) {
            if (sameKey(lastKey, key)) {
                iitr.next()
                return false
            }
            lastKey = safeCopy(lastKey, key)
        }
        
        // 跳过删除/过期
        let vs = iitr.value()
        if (isDeletedOrExpired(vs.meta, vs.expiresAt)) {
            iitr.next()
            return false
        }
        
        let newItem = newItem()
        fill(newItem)
        
        iitr.next()
        
        if (!opt.reverse || !iitr.valid()) {
            setItem(newItem)
            return true
        }
        
        // 反向迭代：需要检查下一个是否是同一 key 的更新版本
        let nextTs = parseTs(iitr.key())
        let nextKey = parseKey(iitr.key())
        
        if (nextTs <= readTs && nextKey == newItem.key) {
            // 有更新的版本，继续查找
            return parseItem()
        }
        
        setItem(newItem)
        return true
    }
    
    // 填充 item
    private func fill(item: Item): Unit {
        let vs = iitr.value()
        item.meta = vs.meta
        item.userMeta = vs.userMeta
        item.expiresAt = vs.expiresAt
        item.version = parseTs(iitr.key())
        item.key = safeCopy(item.key, parseKey(iitr.key()))
        item.vptr = safeCopy(item.vptr, vs.value)
        item.val = null
        
        // 预取值
        if (opt.prefetchValues) {
            item.wg.add(1)
            spawn {
                item.prefetchValue()
                item.wg.done()
            }
        }
    }
    
    private func setItem(item: Item): Unit {
        if (this.item == null) {
            this.item = item
        } else {
            data.push(item)
        }
    }
    
    private func newItem(): Item {
        var item = waste.pop()
        if (item == null) {
            item = Item(txn: txn)
        }
        return item
    }
    
    private func hasPrefix(): Bool {
        if (!opt.reverse && opt.prefix.size > 0) {
            return parseKey(iitr.key()).startsWith(opt.prefix)
        }
        return true
    }
    
    private func prefetch(): Unit {
        let prefetchSize = if (opt.prefetchValues && opt.prefetchSize > 1) {
            opt.prefetchSize
        } else {
            2
        }
        
        var count = 0
        item = null
        
        while (iitr.valid() && hasPrefix()) {
            if (!parseItem()) {
                continue
            }
            
            count++
            if (count == prefetchSize) {
                break
            }
        }
    }
}

// IteratorOptions
public struct IteratorOptions {
    var prefetchSize: Int = 100
    var prefetchValues: Bool = true
    var reverse: Bool = false
    var allVersions: Bool = false
    var internalAccess: Bool = false
    var prefix: Array<Byte> = []
    var sinceTs: UInt64 = 0
    
    // 包内部使用
    var prefixIsKey: Bool = false
}

// Item
public class Item {
    var key: Array<Byte>
    var vptr: Array<Byte>
    var val: ?Array<Byte>
    var version: UInt64
    var expiresAt: UInt64
    var meta: Byte
    var userMeta: Byte
    
    private let txn: Transaction
    private let wg: WaitGroup
    private var status: ItemStatus
    private var err: ?Exception
    
    // Key
    public func key(): Array<Byte> {
        return key
    }
    
    // KeyCopy
    public func keyCopy(dst: Array<Byte>): Array<Byte> {
        return safeCopy(dst, key)
    }
    
    // Version
    public func version(): UInt64 {
        return version
    }
    
    // Value
    public func value(fn: func(Array<Byte>): ?Exception): ?Exception {
        wg.wait()
        
        if (status == Prefetched) {
            if (err == null && fn != null) {
                return fn(val)
            }
            return err
        }
        
        let (buf, cb) = yieldItemValue()
        defer {
            if (cb != null) {
                cb()
            }
        }
        
        if (fn != null) {
            return fn(buf)
        }
        
        return null
    }
    
    // ValueCopy
    public func valueCopy(dst: Array<Byte>): (Array<Byte>, ?Exception) {
        wg.wait()
        
        if (status == Prefetched) {
            return (safeCopy(dst, val), err)
        }
        
        let (buf, cb) = yieldItemValue()
        defer {
            if (cb != null) {
                cb()
            }
        }
        
        return (safeCopy(dst, buf), err)
    }
    
    // ... 其他方法 ...
}
```

#### 3.4.3 测试用例

```cangjie
@Test
func testIteratorBasic() {
    let db = openTestDB()
    defer { db.close() }
    
    // 写入测试数据
    db.update(func(txn: Transaction): ?Exception {
        txn.set("key1".toArray(), "value1".toArray())
        txn.set("key2".toArray(), "value2".toArray())
        txn.set("key3".toArray(), "value3".toArray())
        return null
    })
    
    // 迭代
    let txn = db.newTransaction(update: false)
    let iter = txn.newIterator(IteratorOptions())
    defer { iter.close() }
    
    var count = 0
    iter.rewind()
    while (iter.valid()) {
        let item = iter.item().unwrap()
        Assert.isTrue(item.key().startsWith("key".toArray()))
        count++
        iter.next()
    }
    
    Assert.equal(3, count)
}

@Test
func testIteratorReverse() {
    let db = openTestDB()
    defer { db.close() }
    
    db.update(func(txn: Transaction): ?Exception {
        txn.set("key1".toArray(), "value1".toArray())
        txn.set("key2".toArray(), "value2".toArray())
        txn.set("key3".toArray(), "value3".toArray())
        return null
    })
    
    let txn = db.newTransaction(update: false)
    let opt = IteratorOptions(reverse: true)
    let iter = txn.newIterator(opt)
    defer { iter.close() }
    
    let keys = ArrayList<Array<Byte>>()
    iter.rewind()
    while (iter.valid()) {
        let item = iter.item().unwrap()
        keys.add(item.key())
        iter.next()
    }
    
    Assert.equal("key3", keys[0].toString())
    Assert.equal("key2", keys[1].toString())
    Assert.equal("key1", keys[2].toString())
}

@Test
func testIteratorPrefix() {
    let db = openTestDB()
    defer { db.close() }
    
    db.update(func(txn: Transaction): ?Exception {
        txn.set("prefix1/key1".toArray(), "value1".toArray())
        txn.set("prefix1/key2".toArray(), "value2".toArray())
        txn.set("prefix2/key1".toArray(), "value3".toArray())
        return null
    })
    
    let txn = db.newTransaction(update: false)
    let opt = IteratorOptions(prefix: "prefix1/".toArray())
    let iter = txn.newIterator(opt)
    defer { iter.close() }
    
    var count = 0
    iter.rewind()
    while (iter.valid()) {
        let item = iter.item().unwrap()
        Assert.isTrue(item.key().startsWith("prefix1/".toArray()))
        count++
        iter.next()
    }
    
    Assert.equal(2, count)
}

@Test
func testIteratorSeek() {
    let db = openTestDB()
    defer { db.close() }
    
    db.update(func(txn: Transaction): ?Exception {
        txn.set("key1".toArray(), "value1".toArray())
        txn.set("key2".toArray(), "value2".toArray())
        txn.set("key3".toArray(), "value3".toArray())
        return null
    })
    
    let txn = db.newTransaction(update: false)
    let iter = txn.newIterator(IteratorOptions())
    defer { iter.close() }
    
    iter.seek("key2".toArray())
    
    Assert.isTrue(iter.valid())
    let item = iter.item().unwrap()
    Assert.equal("key2", item.key().toString())
}

@Test
func testIteratorConsistency() {
    let db = openTestDB()
    defer { db.close() }
    
    // 事务 1：写入数据
    let txn1 = db.newTransaction(update: true)
    txn1.set("key1".toArray(), "value1".toArray())
    txn1.commit()
    
    // 创建迭代器
    let txn2 = db.newTransaction(update: false)
    let iter = txn2.newIterator(IteratorOptions())
    
    // 事务 3：写入更多数据
    let txn3 = db.newTransaction(update: true)
    txn3.set("key2".toArray(), "value2".toArray())
    txn3.commit()
    
    // 迭代器应该只能看到 key1
    var count = 0
    iter.rewind()
    while (iter.valid()) {
        count++
        iter.next()
    }
    
    Assert.equal(1, count)
    
    iter.close()
}

@Test
func testIteratorAllVersions() {
    let db = openTestDB()
    defer { db.close() }
    
    // 写入同一 key 的多个版本
    db.set("key1".toArray(), "v1".toArray())
    db.set("key1".toArray(), "v2".toArray())
    db.set("key1".toArray(), "v3".toArray())
    
    let txn = db.newTransaction(update: false)
    let opt = IteratorOptions(allVersions: true)
    let iter = txn.newIterator(opt)
    defer { iter.close() }
    
    iter.seek("key1".toArray())
    
    var versions = ArrayList<UInt64>()
    while (iter.valid()) {
        let item = iter.item().unwrap()
        if (item.key() != "key1".toArray()) {
            break
        }
        versions.add(item.version())
        iter.next()
    }
    
    Assert.equal(3, versions.size)
}
```

---

### 3.5 Snapshot（快照）

#### 3.5.1 职责

- 提供一致性快照读
- 不受后续写入影响
- 基于事务实现

#### 3.5.2 核心接口

**文件：** `src/db/snapshot.cj`

```cangjie
public class Snapshot {
    private let db: DB
    private let readTs: UInt64
    private var discarded: Bool
    
    // 初始化（由 DB 创建）
    init(db: DB) {
        this.db = db
        this.readTs = db.oracle.readTs()
        this.discarded = false
    }
    
    // Get
    public func get(key: Array<Byte>): ?Item {
        if (discarded) {
            throw ErrDiscardedTxn
        }
        
        // 创建临时事务
        let txn = db.newTransactionAt(readTs, update: false)
        defer {
            txn.discard()
        }
        
        return txn.get(key)
    }
    
    // NewIterator
    public func newIterator(opt: IteratorOptions): Iterator {
        if (discarded) {
            throw ErrDiscardedTxn
        }
        
        let txn = db.newTransactionAt(readTs, update: false)
        return txn.newIterator(opt)
    }
    
    // ReadTs
    public func readTs(): UInt64 {
        return readTs
    }
    
    // Discard
    public func discard(): Unit {
        if (discarded) {
            return
        }
        discarded = true
        
        // 标记读完成
        db.oracle.readMark.done(readTs)
    }
}

// DB 扩展
public class DB {
    // NewSnapshot
    public func newSnapshot(): Snapshot {
        if (isClosed()) {
            panic(ErrDBClosed)
        }
        
        return Snapshot(db: this)
    }
}
```

#### 3.5.3 测试用例

```cangjie
@Test
func testSnapshotBasic() {
    let db = openTestDB()
    defer { db.close() }
    
    db.set("key1".toArray(), "value1".toArray())
    
    let snap = db.newSnapshot()
    defer { snap.discard() }
    
    // 修改数据
    db.set("key1".toArray(), "modified".toArray())
    
    // 快照应该看到旧值
    let item = snap.get("key1".toArray())
    Assert.equal("value1", item.unwrap().value.toString())
    
    // 新事务应该看到新值
    let item2 = db.get("key1".toArray())
    Assert.equal("modified", item2.unwrap().toString())
}

@Test
func testSnapshotIterator() {
    let db = openTestDB()
    defer { db.close() }
    
    db.update(func(txn: Transaction): ?Exception {
        txn.set("key1".toArray(), "value1".toArray())
        txn.set("key2".toArray(), "value2".toArray())
        return null
    })
    
    let snap = db.newSnapshot()
    defer { snap.discard() }
    
    // 添加更多数据
    db.set("key3".toArray(), "value3".toArray())
    
    // 快照迭代器应该只看到前两个 key
    let iter = snap.newIterator(IteratorOptions())
    defer { iter.close() }
    
    var count = 0
    iter.rewind()
    while (iter.valid()) {
        count++
        iter.next()
    }
    
    Assert.equal(2, count)
}

@Test
func testSnapshotIsolation() {
    let db = openTestDB()
    defer { db.close() }
    
    // 创建快照
    let snap = db.newSnapshot()
    
    // 写入数据
    db.set("key1".toArray(), "value1".toArray())
    
    // 快照应该看不到新数据
    let item = snap.get("key1".toArray())
    Assert.isTrue(item.isNone())
    
    snap.discard()
}
```

---

## 4. 实施计划

### 4.1 Week 1: WaterMark + Oracle ✅ 已完成

**时间：** Day 1-7

**任务清单：**

| 任务 | 预计时间 | 文件 | 状态 |
|------|---------|------|------|
| WaterMark 基础实现 | 4h | `src/db/watermark.cj` | ✅ 已完成 |
| WaterMark 单元测试 | 3h | `src/db/watermark_test.cj` | ✅ 已完成 (6个测试) |
| Oracle 基础实现 | 4h | `src/db/oracle.cj` | ✅ 已完成 |
| Oracle 冲突检测 | 3h | `src/db/oracle.cj` | ✅ 已完成 |
| Oracle 单元测试 | 3h | `src/db/oracle_test.cj` | ✅ 已完成 (9个测试) |
| 集成测试 | 2h | - | ✅ 已完成 |

**验收标准：**
- ✅ WaterMark 追踪完成情况正常
- ✅ Oracle 时间戳分配正确
- ✅ 冲突检测准确
- ✅ 单元测试 15 个，全部通过

---

### 4.2 Week 2: 完整事务 ✅ 已完成

**时间：** Day 8-14

**任务清单：**

| 任务 | 预计时间 | 文件 | 状态 |
|------|---------|------|------|
| Transaction 读写追踪 | 4h | `src/db/transaction.cj` | ✅ 已完成 |
| Transaction 提交逻辑 | 4h | `src/db/transaction.cj` | ✅ 已完成 |
| Transaction 冲突检测集成 | 3h | `src/db/transaction.cj` | ✅ 已完成 |
| Transaction 单元测试 | 4h | `src/db/transaction_test.cj` | ✅ 已完成 (9个测试) |
| DB 集成（view/update） | 2h | `src/db/db.cj` | ✅ 已完成 |
| 集成测试 | 3h | - | ✅ 已完成 |

**验收标准：**
- ✅ Transaction 读写集合追踪正确
- ✅ 冲突检测工作正常
- ✅ view/update API 正常
- ✅ 单元测试 20 个，全部通过

---

### 4.3 Week 3: Iterator 🚀 进行中

**时间：** Day 15-21

**任务清单：**

| 任务 | 预计时间 | 文件 | 状态 |
|------|---------|------|------|
| Iterator 基础实现 | 4h | `src/db/iterator.cj` | 🚀 进行中 |
| Iterator 前向/反向 | 3h | `src/db/iterator.cj` | ⏸️ 待开始 |
| Iterator 前缀/Seek | 3h | `src/db/iterator.cj` | ⏸️ 待开始 |
| Iterator 预取优化 | 2h | `src/db/iterator.cj` | ⏸️ 待开始 |
| Iterator 单元测试 | 4h | `src/db/iterator_test.cj` | ⏸️ 待开始 |
| 性能测试 | 2h | - | ⏸️ 待开始 |

**验收标准：**
- ✅ Iterator 一致性读取正常
- ✅ 前向/反向迭代正确
- ✅ 前缀过滤和 Seek 正常
- ✅ 单元测试 ≥ 12 个，全部通过

---

### 4.4 Week 4: Snapshot + 集成测试

**时间：** Day 22-28

**任务清单：**

| 任务 | 预计时间 | 文件 | 状态 |
|------|---------|------|------|
| Snapshot 实现 | 3h | `src/db/snapshot.cj` | ⏸️ 待开始 |
| Snapshot 单元测试 | 2h | `src/db/snapshot_test.cj` | ⏸️ 待开始 |
| 并发事务测试 | 4h | - | ⏸️ 待开始 |
| 压力测试 | 4h | - | ⏸️ 待开始 |
| 性能优化 | 3h | - | ⏸️ 待开始 |
| 文档完善 | 2h | - | ⏸️ 待开始 |

**验收标准：**
- ✅ Snapshot 隔离性正确
- ✅ 并发事务无死锁
- ✅ 性能符合预期
- ✅ 集成测试 ≥ 10 个，全部通过

---

## 5. 测试策略

### 5.1 单元测试

**目标覆盖率：** ≥ 80%

**测试分布：**
- WaterMark: 8 个测试
- Oracle: 12 个测试
- Transaction: 15 个测试
- Iterator: 12 个测试
- Snapshot: 6 个测试

**总计：** 53 个单元测试

### 5.2 集成测试

**关键场景：**
1. 并发事务提交
2. 事务冲突检测
3. 一致性读取
4. 快照隔离
5. 迭代器一致性

### 5.3 并发测试

**场景：**
- 100 个并发事务
- 读写混合场景
- 高冲突场景

### 5.4 性能测试

**基准场景：**
- 1000 次事务提交
- 10000 次 Get 操作
- 1000 次 Iterator 全表扫描

---

## 6. 风险管理

### 6.1 技术风险

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|----------|
| 冲突检测误判 | 低 | 高 | 大量单元测试和并发测试 |
| WaterMark 死锁 | 中 | 高 | 仔细设计等待逻辑 |
| Iterator 性能差 | 中 | 中 | 预取优化和性能测试 |
| 并发 bug | 高 | 高 | 使用竞态检测工具 |

### 6.2 缓解策略

1. **单元测试优先** - 每个模块完成立即测试
2. **增量集成** - 每周集成一次，早发现问题
3. **并发测试** - 专门的并发测试套件
4. **性能监控** - 持续监控关键指标

---

## 7. 兼容性说明

### 7.1 Go BadgerDB v4 兼容性

**兼容特性：**
- ✅ SSI 隔离级别
- ✅ Oracle 时间戳管理
- ✅ 冲突检测机制
- ✅ Iterator API
- ✅ Snapshot API
- ✅ view/update API

**不兼容特性（Managed DB）：**
- ❌ NewTransactionAt（手动管理时间戳）
- ❌ NewWriteBatchAt
- ❌ SetDiscardTs

### 7.2 API 兼容性

**Transaction API:**
```cangjie
// Go BadgerDB
txn := db.NewTransaction(true)
txn.Set(key, val)
txn.Commit()

// badger-cj
let txn = db.newTransaction(update: true)
txn.set(key, val)
txn.commit()
```

**Iterator API:**
```cangjie
// Go BadgerDB
itr := txn.NewIterator(badger.DefaultIteratorOptions)
defer itr.Close()
for itr.Rewind(); itr.Valid(); itr.Next() {
    item := itr.Item()
}

// badger-cj
let iter = txn.newIterator(IteratorOptions())
defer { iter.close() }
iter.rewind()
while (iter.valid()) {
    let item = iter.item().unwrap()
    iter.next()
}
```

---

## 8. 性能目标

### 8.1 吞吐量目标

| 操作 | 目标 | Go BadgerDB 参考 |
|------|------|-----------------|
| 单次 Get | < 1ms | ~0.5ms |
| 单次 Set | < 1ms | ~0.8ms |
| 事务提交 | < 2ms | ~1.5ms |
| Iterator (1000 items) | < 10ms | ~8ms |

### 8.2 并发目标

| 场景 | 目标 | 说明 |
|------|------|------|
| 并发事务 | 100 TPS | 100 个事务/秒 |
| 冲突率 | < 10% | 在低冲突场景下 |
| 延迟 | P99 < 10ms | 99% 请求延迟 |

---

## 9. 成功标准

### 9.1 功能验收

- [x] Week 1 单元测试通过（15 个 - WaterMark: 6, Oracle: 9）
- [x] Week 2 单元测试通过（20 个 - Transaction: 9, Oracle: 9, API: 2）
- [ ] Week 3 Iterator 测试通过（≥ 12 个）
- [ ] Week 4 集成测试通过（10 个）
- [ ] 并发事务正常
- [ ] 冲突检测准确率 100%

### 9.2 性能验收

- [ ] 单次 Get < 1ms
- [ ] 单次 Set < 1ms
- [ ] 100 个并发事务无死锁
- [ ] 性能符合预期

### 9.3 兼容性验收

- [ ] 与 Go BadgerDB v4 语义兼容
- [ ] API 命名规范一致
- [ ] 行为一致

---

## 10. 后续扩展

### 10.1 Phase 5 扩展点

**Managed DB：**
- 手动管理时间戳
- SetDiscardTs API
- NewTransactionAt API

**Stream API：**
- 大规模数据处理
- 并发流处理
- 分布式计算支持

### 10.2 接口预留

所有 Phase 5 需要的接口已在 Phase 4 预留：
- Oracle 支持 isManaged 模式
- Transaction 支持 commitTs 设置
- DB 支持 NewTransactionAt

---

**文档版本：** v1.1  
**创建时间：** 2026-03-08  
**更新时间：** 2026-03-08  
**作者：** AI Code Agent  
**状态：** Week 1-2 ✅ 完成，Week 3 🚀 进行中
