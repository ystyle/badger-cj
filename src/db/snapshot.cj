package badgercj.db

/**
 * Snapshot - 一致性快照读
 * 
 * 提供一致性快照读，不受后续写入影响
 * 
 * 参考：github.com/dgraph-io/badger/v4/db.go
 */
public class Snapshot {
    private let db: Badger
    private let readTs: UInt64
    private var discarded: Bool
    
    public init(db: Badger) {
        this.db = db
        this.readTs = db.oracle.readTs()
        this.discarded = false
    }
    
    public func get(key: Array<Byte>): ?Item {
        if (discarded) {
            return None
        }
        
        let tmpTxn = Transaction(db, update: false, readTs: readTs)
        let valueOpt = tmpTxn.get(key)
        if (let Some(value) <- valueOpt) {
            return Some(Item(key, value))
        }
        return None
    }
    
    public func newIterator(opt!: IteratorOptions = IteratorOptions(reverse: false)): Iterator {
        if (discarded) {
            throw Exception("Snapshot discarded")
        }
        
        let tmpTxn = Transaction(db, update: false, readTs: readTs)
        return tmpTxn.newIterator(opt: opt)
    }
    
    public func getReadTs(): UInt64 {
        return readTs
    }
    
    public func discard(): Unit {
        if (discarded) {
            return
        }
        discarded = true
    }
}
