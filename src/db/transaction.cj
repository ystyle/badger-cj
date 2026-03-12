package badgercj.db

import std.collection.*
import std.sync.*
import std.overflow.*

let TxnMetaValue: Byte = 0x00
let TxnMetaDelete: Byte = 0x01

public struct TxnEntry {
    public let key: Array<Byte>
    public let value: Array<Byte>
    public let meta: Byte
    
    public init(key: Array<Byte>, value: Array<Byte>, meta: Byte) {
        this.key = key
        this.value = value
        this.meta = meta
    }
    
    public func isDelete(): Bool {
        return meta == TxnMetaDelete
    }
}

public class Transaction {
    private let db: Badger
    private let update: Bool
    private let oracle: Oracle
    
    public let readTs: UInt64
    private var commitTs: UInt64
    
    public let reads: HashSet<UInt64>
    public let conflictKeys: HashSet<UInt64>
    
    private let writes: ArrayList<TxnEntry>
    private var committed: Bool
    private var discarded: Bool
    
    public init(db: Badger, update!: Bool = true, readTs!: UInt64 = 0) {
        this.db = db
        this.update = update
        this.oracle = db.oracle
        
        if (readTs > 0) {
            this.readTs = readTs
        } else {
            this.readTs = oracle.readTs()
        }
        this.commitTs = 0
        
        this.reads = HashSet<UInt64>()
        this.conflictKeys = HashSet<UInt64>()
        
        this.writes = ArrayList<TxnEntry>()
        this.committed = false
        this.discarded = false
    }
    
    public func get(key: Array<Byte>): Option<Array<Byte>> {
        if (discarded) {
            throw Exception("Transaction discarded")
        }
        
        for (entry in writes) {
            if (keysEqual(entry.key, key)) {
                if (entry.isDelete()) {
                    return None
                }
                return Some(entry.value)
            }
        }
        
        addReadKey(key)
        
        let result = db.get(key, readTsOpt: Some(readTs))
        if (result.isSome()) {
            if (let Some(vs) <- result) {
                return Some(vs.value)
            }
        }
        
        return None
    }
    
    public func set(key: Array<Byte>, value: Array<Byte>): Unit {
        if (!update) {
            throw Exception("Read-only transaction")
        }
        if (discarded) {
            throw Exception("Transaction discarded")
        }
        
        addConflictKey(key)
        writes.add(TxnEntry(key, value, TxnMetaValue))
    }
    
    public func delete(key: Array<Byte>): Unit {
        if (!update) {
            throw Exception("Read-only transaction")
        }
        if (discarded) {
            throw Exception("Transaction discarded")
        }
        
        addConflictKey(key)
        writes.add(TxnEntry(key, [], TxnMetaDelete))
    }
    
    public func commit(): Unit {
        if (committed || discarded) {
            throw Exception("Transaction already committed or discarded")
        }
        
        if (writes.isEmpty()) {
            discard()
            return
        }
        
        let txnState = TxnState(readTs)
        txnState.reads = reads
        txnState.conflictKeys = conflictKeys
        
        commitTs = oracle.newCommitTs(txnState)
        
        let req = db.reqPool.get(commitTs)
        for (entry in writes) {
            req.addEntry(entry.key, entry.value, isDelete: entry.isDelete())
        }
        
        db.writeCh.add(req)
        req.wait()
        
        oracle.doneCommit(commitTs)
        db.reqPool.put(req)
        committed = true
    }
    
    public func rollback(): Unit {
        writes.clear()
        discard()
    }
    
    public func discard(): Unit {
        if (!discarded) {
            oracle.doneRead(TxnState(readTs))
            discarded = true
        }
    }
    
    public func getDB(): Badger {
        return db
    }
    
    public func isUpdate(): Bool {
        return update
    }
    
    public func newIterator(opt!: IteratorOptions = IteratorOptions(reverse: false)): Iterator {
        if (discarded) {
            throw Exception("Transaction discarded")
        }
        return Iterator(this, opt)
    }
    
    public func getWrites(): ArrayList<TxnEntry> {
        return writes
    }
    
    public func isCommitted(): Bool {
        return committed
    }
    
    public func isDiscarded(): Bool {
        return discarded
    }
    
    private func addReadKey(key: Array<Byte>): Unit {
        let fp = hashKey(key)
        reads.add(fp)
    }
    
    private func addConflictKey(key: Array<Byte>): Unit {
        let fp = hashKey(key)
        conflictKeys.add(fp)
    }
    
    private func hashKey(key: Array<Byte>): UInt64 {
        var hash: UInt64 = 5381
        for (b in key) {
            hash = hash.wrappingMul(33).wrappingAdd(UInt64(b))
        }
        return hash
    }
    
    private func keysEqual(a: Array<Byte>, b: Array<Byte>): Bool {
        if (a.size != b.size) {
            return false
        }
        for (i in 0..a.size) {
            if (a[i] != b[i]) {
                return false
            }
        }
        return true
    }
}
