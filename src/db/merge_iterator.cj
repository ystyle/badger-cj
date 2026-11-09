package badgercj.db

import std.collection.*
import badgercj.utils.{compareKeys, keysEqual}

/**
 * MergeIterator - 合并多个迭代器
 * 
 * 按key顺序合并多个迭代器的数据，跳过重复的key
 * 
 * 参考：github.com/dgraph-io/badger/v4/table/merge_iterator.go
 */
public class MergeIterator {
    private let iters: ArrayList<SimpleIterator>
    private let reverse: Bool
    private var current: SimpleIterator
    private var curKey: Array<Byte>
    private var closed: Bool
    
    public init(iters: ArrayList<SimpleIterator>, reverse!: Bool = false) {
        this.iters = iters
        this.reverse = reverse
        this.current = SimpleIterator()
        this.curKey = []
        this.closed = false
        
        if (iters.size > 0) {
            for (iter in iters) {
                iter.rewind()
            }
            fix()
        }
    }
    
    public func valid(): Bool {
        return current.valid()
    }
    
    public func next(): Unit {
        if (!current.valid()) {
            return
        }
        
        while (current.valid()) {
            let key = current.key()
            if (!keysEqual(key, curKey)) {
                break
            }
            current.next()
            fix()
        }
        setCurrent()
    }
    
    public func key(): Array<Byte> {
        return current.key()
    }
    
    public func value(): Array<Byte> {
        return current.value()
    }
    
    public func rewind(): Unit {
        curKey = []
        for (iter in iters) {
            iter.rewind()
        }
        fix()
        setCurrent()
    }
    
    public func seek(key: Array<Byte>): Unit {
        curKey = []
        for (iter in iters) {
            iter.seek(key)
        }
        fix()
        setCurrent()
    }
    
    /**
     * 关闭所有子迭代器（放掉它们持有的表引用）。幂等。
     * 不关闭 = 旧表映射与表文件永不释放，磁盘随 compaction 单调增长。
     */
    public func close(): Unit {
        if (closed) {
            return
        }
        closed = true
        for (iter in iters) {
            iter.close()
        }
    }
    
    private func fix(): Unit {
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
                    } else if (cmp == 0) {
                        iter.next()
                    }
                } else {
                    if (cmp < 0) {
                        bestKey = iterKey
                        bestIter = iter
                    } else if (cmp == 0) {
                        iter.next()
                    }
                }
            }
        }
        
        current = bestIter
    }
    
    private func setCurrent(): Unit {
        if (current.valid()) {
            curKey = current.key().clone()
        } else {
            curKey = []
        }
    }
}

/**
 * SimpleIterator - 简单迭代器接口
 * 
 * 统一不同类型迭代器的接口
 */
public open class SimpleIterator {
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
    
    public open func valid(): Bool {
        return valid_
    }
    
    public open func key(): Array<Byte> {
        return key_
    }
    
    public open func value(): Array<Byte> {
        return value_
    }
    
    public open func next(): Unit {
        // 空实现
    }
    
    public open func rewind(): Unit {
        // 空实现
    }
    
    // key: 定位键（空迭代器忽略此参数）
    public open func seek(_: Array<Byte>): Unit {
        // 空实现
    }
    
    // 关闭迭代器：持有表引用的实现必须在这里归还（默认无资源可释放）
    public open func close(): Unit {
        // 空实现
    }
}