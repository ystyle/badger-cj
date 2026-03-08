package badgercj.db

import std.collection.*
import badgercj.table.*

/**
 * MemTableIterator - MemTable 迭代器包装器
 * 
 * 将 SkipIterator 包装成 SimpleIterator 接口
 */
public class MemTableIterator {
    private let skipIter: SkipIterator
    private var currentKey: Array<Byte>
    private var currentValue: Array<Byte>
    private var valid_: Bool
    
    public init(mt: MemTable) {
        this.skipIter = mt.iterator()
        this.currentKey = []
        this.currentValue = []
        this.valid_ = false
        
        advance()
    }
    
    public func valid(): Bool {
        return valid_
    }
    
    public func key(): Array<Byte> {
        return currentKey
    }
    
    public func value(): Array<Byte> {
        return currentValue
    }
    
    public func next(): Unit {
        advance()
    }
    
    public func rewind(): Unit {
        // SkipIterator 不支持 rewind，需要重新创建
    }
    
    public func seek(key: Array<Byte>): Unit {
        // SkipIterator 不支持 seek
    }
    
    private func advance(): Unit {
        if (skipIter.hasNext()) {
            if (let Some((key, vs)) <- skipIter.next()) {
                currentKey = key
                currentValue = vs.value
                valid_ = true
            } else {
                valid_ = false
            }
        } else {
            valid_ = false
        }
    }
}