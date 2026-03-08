package badgercj.db

import std.collection.*
import badgercj.table.*

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
    private var closed: Bool
    
    public init(txn: Transaction, opt: IteratorOptions) {
        this.txn = txn
        this.readTs = txn.readTs
        this.opt = opt
        this.closed = false
        
        let iters = ArrayList<SimpleIterator>()
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
            return
        }
        
        let key = iitr.key()
        let value = iitr.value()
        
        item_ = Item(key, value)
        
        let fp = hashKey(key)
        txn.reads.add(fp)
    }
    
    private func hashKey(key: Array<Byte>): UInt64 {
        var hash: UInt64 = 5381
        for (b in key) {
            hash = ((hash << 5) + hash) + UInt64(b)
        }
        return hash
    }
}