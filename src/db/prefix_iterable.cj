package badgercj.db

import std.core.Iterator as StdIterator
import std.core.Iterable as StdIterable

/**
 * PrefixIterable - 支持 for-in 遍历前缀 key
 * 
 * 用法：
 * ```cangjie
 * for (item in db.scan("user_".toArray())) {
 *     println(item.key())
 * }
 * ```
 */
public class PrefixIterable <: StdIterable<Item> {
    private let db: Badger
    private let prefix: Array<Byte>
    private let reverse: Bool
    private let allVersions: Bool
    
    public init(db: Badger, prefix: Array<Byte>, reverse!: Bool = false, allVersions!: Bool = false) {
        this.db = db
        this.prefix = prefix
        this.reverse = reverse
        this.allVersions = allVersions
    }
    
    public func iterator(): PrefixIterator {
        let opt = IteratorOptions(prefix: prefix, reverse: reverse, allVersions: allVersions)
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator(opt: opt)
        iter.rewind()
        PrefixIterator(iter, txn)
    }
}

/**
 * PrefixIterator - for-in 迭代器包装
 * 
 * 实现 std.collection.Iterator 接口
 */
public class PrefixIterator <: StdIterator<Item> {
    private let iter: Iterator
    private let txn: Transaction
    private var closed: Bool
    
    public init(iter: Iterator, txn: Transaction) {
        this.iter = iter
        this.txn = txn
        this.closed = false
    }
    
    public func next(): Option<Item> {
        if (closed || !iter.valid()) {
            return None
        }
        let item = iter.item()
        iter.next()
        Some(item)
    }
    
    public func close(): Unit {
        if (!closed) {
            iter.close()
            txn.discard()
            closed = true
        }
    }
}