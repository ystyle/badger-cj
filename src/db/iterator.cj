package badgercj.db

import std.collection.ArrayList

/**
 * Iterator - 事务级一致性迭代器
 * 
 * 基于 readTs 提供一致性快照读
 * 
 * 参考：github.com/dgraph-io/badger/v4/iterator.go
 */
public class Iterator {
    private let txn: Transaction
    private let readTs: UInt64
    private let opt: IteratorOptions
    
    private var iitr: MergeIterator
    private var item_: Item
    private var lastKey: Array<Byte>
    private var closed: Bool
    
    public init(txn: Transaction, opt: IteratorOptions) {
        this.txn = txn
        this.readTs = txn.readTs
        this.opt = opt
        this.closed = false
        this.lastKey = []
        
        // 构造迭代器链
        let iters = ArrayList<SimpleIterator>()
        
        // 1. 添加 pending writes 迭代器（如果是 update 事务）
        if (txn.isUpdate()) {
            let writes = txn.getWrites()
            if (!writes.isEmpty()) {
                iters.add(PendingWritesIterator(writes, reverse: opt.reverse))
            }
        }
        
        // 2. 添加 MemTable 迭代器
        let db = txn.getDB()
        let tables = db.getMemTables()
        for (table in tables) {
            iters.add(MemTableIterator(table, reverse: opt.reverse))
        }
        
        // 3. 添加 SSTable 迭代器
        let lc = db.getLevelsController()
        lc.appendIterators(iters, opt)
        
        // 合并迭代器
        this.iitr = MergeIterator(iters, reverse: opt.reverse)
        this.item_ = Item([], [])
    }
    
    public func rewind(): Unit {
        if (closed) {
            return
        }
        iitr.rewind()
        parseItem()
    }
    
    public func valid(): Bool {
        if (closed || !iitr.valid()) {
            return false
        }
        
        return true
    }
    
    public func next(): Unit {
        if (closed) {
            return
        }
        iitr.next()
        parseItem()
    }
    
    public func item(): Item {
        return item_
    }
    
    public func seek(key: Array<Byte>): Unit {
        if (closed) {
            return
        }
        iitr.seek(key)
        parseItem()
    }
    
    public func close(): Unit {
        if (closed) {
            return
        }
        closed = true
    }
    
    private func parseItem(): Unit {
        if (!iitr.valid()) {
            item_ = Item([], [])
            return
        }
        
        let key = iitr.key()
        let value = iitr.value()
        
        // 去重：如果当前 key 与上一个 key 相同，跳过
        if (lastKey.size > 0 && keysEqual(lastKey, key)) {
            iitr.next()
            parseItem()
            return
        }
        
        lastKey = key
        item_ = Item(key, value)
        
        let fp = hashKey(key)
        txn.reads.add(fp)
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
    
    private func hashKey(key: Array<Byte>): UInt64 {
        var hash: UInt64 = 5381
        for (b in key) {
            hash = ((hash << 5) + hash) + UInt64(b)
        }
        return hash
    }
}