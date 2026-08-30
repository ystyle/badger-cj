package badgercj.db

import std.collection.*
import std.sync.*
import std.overflow.*
import badgercj.table.Meta
import badgercj.table.ValueStruct
import badgercj.utils.{hashKey, keysEqual}

let TxnMetaValue: Byte = 0x00
let TxnMetaDelete: Byte = 0x01

public struct TxnEntry {
    public let key: Array<Byte>
    public let value: Array<Byte>
    public let meta: Byte           // 内部标记（TxnMetaValue/TxnMetaDelete）
    public let entryMeta: Byte      // Entry 的 meta（bitDiscardEarlierVersions 等）
    public let userMeta: Byte
    public let expiresAt: UInt64
    
    public init(key: Array<Byte>, value: Array<Byte>, meta: Byte, 
                entryMeta!: Byte = 0, userMeta!: Byte = 0, expiresAt!: UInt64 = 0) {
        this.key = key
        this.value = value
        this.meta = meta
        this.entryMeta = entryMeta
        this.userMeta = userMeta
        this.expiresAt = expiresAt
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
    
    protected let reads: HashSet<UInt64>
    protected let conflictKeys: HashSet<UInt64>
    
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
    
    public func setEntry(e: Entry): Unit {
        if (!update) {
            throw Exception("Read-only transaction")
        }
        if (discarded) {
            throw Exception("Transaction discarded")
        }
        
        addConflictKey(e.key)
        let meta = if (e.isDelete()) { TxnMetaDelete } else { TxnMetaValue }
        writes.add(TxnEntry(e.key, e.value, meta, entryMeta: e.meta, 
                           userMeta: e.userMeta, expiresAt: e.expiresAt))
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
    
    public func commit(): TxnStatus {
        if (committed || discarded) {
            return TxnStatus.Error("Transaction already committed or discarded")
        }
        
        if (writes.isEmpty()) {
            discard()
            return TxnStatus.Ok
        }
        
        let txnState = TxnState(readTs)
        txnState.reads = reads
        txnState.conflictKeys = conflictKeys
        
        let tsOpt = oracle.newCommitTs(txnState)
        if (tsOpt.isNone()) {
            discard()
            return TxnStatus.Conflict
        }
        let commitTs = tsOpt.getOrThrow()
        this.commitTs = commitTs
        
        let req = db.reqPool.get(commitTs)
        for (entry in writes) {
            let txnMeta = entry.entryMeta | Meta.bitTxn
            req.addEntry(entry.key, entry.value, isDelete: entry.isDelete(), 
                         meta: txnMeta, userMeta: entry.userMeta, expiresAt: entry.expiresAt)
        }
        
        let txnKeyWithTs = keyWithTs(db.getTxnKey(), commitTs)
        let finTsBytes = commitTs.toString().toArray()
        req.addEntry(txnKeyWithTs, finTsBytes, meta: Meta.bitFinTxn)
        
        db.writeCh.add(req)
        req.wait()
        
        // 失败必报（对齐 badger-go req.Err）：pipeline 异常时 req 被标记失败，
        // 不再"假装成功"（此前 arena 溢出 / value 超 64KB 编码上限都会静默丢数据）
        if (let Some(msg) <- req.errorOf()) {
            oracle.doneCommit(commitTs)
            db.reqPool.put(req)
            committed = true
            return TxnStatus.Error(msg)
        }
        
        oracle.doneCommit(commitTs)
        db.reqPool.put(req)
        committed = true
        return TxnStatus.Ok
    }
    
    public func commitOrThrow(): Unit {
        match (commit()) {
            case TxnStatus.Ok => 
                let _ = 0
            case TxnStatus.Conflict => throw TxnConflict()
            case TxnStatus.Error(msg) => throw Exception(msg)
        }
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
    
    protected func getDB(): Badger {
        return db
    }
    
    protected func isUpdate(): Bool {
        return update
    }
    
    public func newIterator(opt!: IteratorOptions = IteratorOptions(reverse: false)): Iterator {
        if (discarded) {
            throw Exception("Transaction discarded")
        }
        return Iterator(this, opt)
    }
    
    protected func getWrites(): ArrayList<TxnEntry> {
        return writes
    }
    
    protected func isCommitted(): Bool {
        return committed
    }
    
    protected func isDiscarded(): Bool {
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
}
