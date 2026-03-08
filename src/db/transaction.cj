package badgercj.db

import std.collection.*
import badgercj.table.*

let TxnMetaValue: Byte = 0x00
let TxnMetaDelete: Byte = 0x01

struct TxnEntry {
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
    private let db: DB
    private let readTs: UInt64
    private let writes: ArrayList<TxnEntry>
    private var committed: Bool
    
    public init(db: DB) {
        this.db = db
        this.readTs = db.getVersion()
        this.writes = ArrayList<TxnEntry>()
        this.committed = false
    }
    
    public func get(key: Array<Byte>): Option<Array<Byte>> {
        for (entry in writes) {
            if (keysEqual(entry.key, key)) {
                if (entry.isDelete()) {
                    return None
                }
                return Some(entry.value)
            }
        }
        
        let result = db.get(key)
        if (result.isSome()) {
            if (let Some(vs) <- result) {
                return Some(vs.value)
            }
        }
        
        return None
    }
    
    public func set(key: Array<Byte>, value: Array<Byte>): Unit {
        writes.add(TxnEntry(key, value, TxnMetaValue))
    }
    
    public func delete(key: Array<Byte>): Unit {
        writes.add(TxnEntry(key, [], TxnMetaDelete))
    }
    
    public func commit(): Unit {
        if (committed) {
            throw Exception("Transaction already committed")
        }
        
        for (entry in writes) {
            if (entry.isDelete()) {
                db.delete(entry.key)
            } else {
                db.set(entry.key, entry.value)
            }
        }
        
        committed = true
    }
    
    public func rollback(): Unit {
        writes.clear()
        committed = true
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
