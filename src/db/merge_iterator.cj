package badgercj.db

import std.collection.*

/**
 * MergeIterator - 合并多个迭代器
 * 
 * 按key顺序合并多个迭代器的数据
 * 
 * 参考：github.com/dgraph-io/badger/v4/iterator.go
 */
public class MergeIterator {
    private let iters: ArrayList<SimpleIterator>
    private let reverse: Bool
    private var current: SimpleIterator
    
    public init(iters: ArrayList<SimpleIterator>, reverse!: Bool = false) {
        this.iters = iters
        this.reverse = reverse
        this.current = SimpleIterator()
        
        if (iters.size > 0) {
            findBest()
        }
    }
    
    public func valid(): Bool {
        return current.valid()
    }
    
    public func next(): Unit {
        if (!current.valid()) {
            return
        }
        current.next()
        findBest()
    }
    
    public func key(): Array<Byte> {
        return current.key()
    }
    
    public func value(): Array<Byte> {
        return current.value()
    }
    
    public func rewind(): Unit {
        for (iter in iters) {
            iter.rewind()
        }
        findBest()
    }
    
    public func seek(key: Array<Byte>): Unit {
        for (iter in iters) {
            iter.seek(key)
        }
        findBest()
    }
    
    private func findBest(): Unit {
        var bestIter: SimpleIterator = SimpleIterator()
        var bestKey: Array<Byte> = []
        
        for (iter in iters) {
            if (!iter.valid()) {
                continue
            }
            
            let iterKey = iter.key()
            
            if (bestKey.size == 0) {
                bestKey = iterKey
                bestIter = iter
            } else {
                let cmp = compareKeys(iterKey, bestKey)
                
                if (reverse) {
                    if (cmp > 0) {
                        bestKey = iterKey
                        bestIter = iter
                    }
                } else {
                    if (cmp < 0) {
                        bestKey = iterKey
                        bestIter = iter
                    }
                }
            }
        }
        
        current = bestIter
    }
    
    private func compareKeys(a: Array<Byte>, b: Array<Byte>): Int64 {
        let minLen = if (a.size < b.size) { a.size } else { b.size }
        for (i in 0..minLen) {
            if (a[i] != b[i]) {
                return Int64(a[i]) - Int64(b[i])
            }
        }
        return Int64(a.size) - Int64(b.size)
    }
}

/**
 * SimpleIterator - 简单迭代器接口
 * 
 * 统一不同类型迭代器的接口
 */
public class SimpleIterator {
    private let valid_: Bool
    private let key_: Array<Byte>
    private let value_: Array<Byte>
    
    public init() {
        this.valid_ = false
        this.key_ = []
        this.value_ = []
    }
    
    public init(valid: Bool, key: Array<Byte>, value: Array<Byte>) {
        this.valid_ = valid
        this.key_ = key
        this.value_ = value
    }
    
    public func valid(): Bool {
        return valid_
    }
    
    public func key(): Array<Byte> {
        return key_
    }
    
    public func value(): Array<Byte> {
        return value_
    }
    
    public func next(): Unit {
        // 空实现
    }
    
    public func rewind(): Unit {
        // 空实现
    }
    
    public func seek(key: Array<Byte>): Unit {
        // 空实现
    }
}