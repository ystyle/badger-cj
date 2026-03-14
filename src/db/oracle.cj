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

public class Oracle {
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
    
    public func newCommitTs(txn: TxnState): UInt64 {
        if (isManaged) {
            lock.lock()
            if (hasConflict(txn)) {
                lock.unlock()
                throw TxnConflict()
            }
            lock.unlock()
            return txn.commitTs
        }
        
        if (!detectConflicts || txn.reads.isEmpty()) {
            let ts = nextTxnTs.fetchAdd(1)
            txnMark.begin(ts)
            return ts
        }
        
        lock.lock()
        
        if (hasConflict(txn)) {
            lock.unlock()
            throw TxnConflict()
        }
        
        doneReadInternal(txn)
        cleanupCommittedTransactions()
        
        let ts = nextTxnTs.fetchAdd(1)
        
        if (detectConflicts) {
            committedTxns.add(CommittedTxn(ts, txn.conflictKeys))
        }
        
        lock.unlock()
        txnMark.begin(ts)
        return ts
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