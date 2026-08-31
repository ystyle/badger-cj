package badgercj.db

import std.sync.*
import std.collection.*

public struct CommittedTxn {
    public let ts: UInt64
    public let conflictKeys: HashSet<UInt64>
    
    public init(ts: UInt64, conflictKeys: HashSet<UInt64>) {
        this.ts = ts
        this.conflictKeys = conflictKeys
    }
}

public class TxnConflict <: Exception {
    public init() {
        super("Transaction conflict detected")
    }
}

public class TxnState {
    public let readTs: UInt64
    public var commitTs: UInt64
    public var conflictKeys: HashSet<UInt64>
    public var reads: HashSet<UInt64>
    public var doneRead: Bool
    
    public init(readTs: UInt64) {
        this.readTs = readTs
        this.commitTs = 0
        this.conflictKeys = HashSet<UInt64>()
        this.reads = HashSet<UInt64>()
        this.doneRead = false
    }
}

protected class Oracle {
    private let isManaged: Bool
    private let detectConflicts: Bool
    
    private let lock: Mutex
    private let nextTxnTs: AtomicUInt64
    
    private let txnMark: WaterMark
    private let readMark: WaterMark
    
    private var committedTxns: ArrayList<CommittedTxn>
    private var lastCleanupTs: UInt64
    
    private let running: AtomicBool
    
    public init(isManaged!: Bool = false, detectConflicts!: Bool = true) {
        this.isManaged = isManaged
        this.detectConflicts = detectConflicts
        
        this.lock = Mutex()
        this.nextTxnTs = AtomicUInt64(1)
        
        this.txnMark = WaterMark("badger.TxnTimestamp")
        this.readMark = WaterMark("badger.PendingReads")
        
        this.committedTxns = ArrayList<CommittedTxn>()
        this.lastCleanupTs = 0
        
        this.running = AtomicBool(true)
    }
    
    public func initTs(ts: UInt64): Unit {
        nextTxnTs.store(ts)
    }
    
    public func readTs(): UInt64 {
        if (isManaged) {
            throw IllegalStateException("ReadTs should not be called for managed DB")
        }
        
        let ts = nextTxnTs.load() - 1
        readMark.begin(ts)
        
        return ts
    }
    
    public func nextTs(): UInt64 {
        return nextTxnTs.load()
    }
    
    public func currentTs(): UInt64 {
        let ts = nextTxnTs.load()
        if (ts > 0) {
            return ts - 1
        }
        return 0
    }
    
    public func bumpCommitTs(ts: UInt64): Unit {
        lock.lock()
        if (ts >= nextTxnTs.load()) {
            nextTxnTs.store(ts + 1)
            txnMark.begin(ts)
            txnMark.done(ts)
            txnMark.setDoneUntil(ts)
        }
        lock.unlock()
    }
    
    public func newCommitTs(txn: TxnState): Option<UInt64> {
        if (isManaged) {
            lock.lock()
            if (hasConflict(txn)) {
                lock.unlock()
                return None
            }
            lock.unlock()
            return Some(txn.commitTs)
        }
        
        lock.lock()
        if (detectConflicts && !txn.reads.isEmpty() && hasConflict(txn)) {
            lock.unlock()
            return None
        }
        doneReadInternal(txn)
        cleanupCommittedTransactions()
        
        let ts = nextTxnTs.fetchAdd(1)
        // 对齐 badger-go：所有带冲突键的提交都登记，供后续有 reads 的事务检测——
        // 否则纯写事务不入册，真正的写-写交错检测不到（此前并发压测用 95% 容忍掩盖了该缺口）。
        // 注意：hasConflict 只比较 readTs 之后提交的事务，顺序"读旧版重写"不会误判。
        if (detectConflicts && !txn.conflictKeys.isEmpty()) {
            committedTxns.add(CommittedTxn(ts, txn.conflictKeys))
            // 兜底防无限增长：纯写压测下 readMark 不推进（无读事务）时，仅保留最近窗口
            if (committedTxns.size > 100000) {
                let keep = ArrayList<CommittedTxn>()
                let startIdx = committedTxns.size - 50000
                var i = startIdx
                while (i < committedTxns.size) {
                    keep.add(committedTxns[i])
                    i += 1
                }
                committedTxns = keep
            }
        }
        
        lock.unlock()
        txnMark.begin(ts)
        return Some(ts)
    }
    
    public func newCommitTsOrThrow(txn: TxnState): UInt64 {
        match (newCommitTs(txn)) {
            case Some(ts) => ts
            case None => throw TxnConflict()
        }
    }
    
    public func doneRead(txn: TxnState): Unit {
        if (!txn.doneRead) {
            txn.doneRead = true
            readMark.done(txn.readTs)
        }
    }
    
    private func doneReadInternal(txn: TxnState): Unit {
        if (!txn.doneRead) {
            txn.doneRead = true
            readMark.done(txn.readTs)
        }
    }
    
    public func doneCommit(commitTs: UInt64): Unit {
        if (!isManaged) {
            txnMark.done(commitTs)
            txnMark.setDoneUntil(commitTs)
        }
    }
    
    private func hasConflict(txn: TxnState): Bool {
        if (txn.reads.isEmpty()) {
            return false
        }
        
        for (committedTxn in committedTxns) {
            // 只比较"本事务读取时点（readTs）之后"提交的事务：
            // readTs 之前提交的写已包含在本事务读快照中，不算冲突
            // （否则顺序事务"读到自己上一版再重写"会被误判——如物化幂等重写，
            // 修复前第二次物化必抛 TxnConflict，是"桶点不开"的根因之一）
            if (committedTxn.ts <= txn.readTs) {
                continue
            }
            for (readKey in txn.reads) {
                if (committedTxn.conflictKeys.contains(readKey)) {
                    return true
                }
            }
        }
        
        return false
    }
    
    private func cleanupCommittedTransactions(): Unit {
        if (!detectConflicts) {
            return
        }
        
        let maxReadTs = readMark.doneUntil()
        
        if (maxReadTs == lastCleanupTs) {
            return
        }
        lastCleanupTs = maxReadTs
        
        let newCommittedTxns = ArrayList<CommittedTxn>()
        for (txn in committedTxns) {
            if (txn.ts > maxReadTs) {
                newCommittedTxns.add(txn)
            }
        }
        committedTxns = newCommittedTxns
    }
    
    public func stop(): Unit {
        running.store(false)
        txnMark.stop()
        readMark.stop()
    }
    
    public func doneUntil(ts: UInt64): Unit {
        txnMark.begin(ts)
        txnMark.done(ts)
        txnMark.setDoneUntil(ts)
    }
    
    private func waitForTxnMark(ts: UInt64): Unit {
        var retries = 0
        let maxRetries = 1000
        while (retries < maxRetries && running.load()) {
            if (txnMark.doneUntil() >= ts) {
                return
            }
            sleep(Duration.millisecond * 1)
            retries++
        }
    }
}