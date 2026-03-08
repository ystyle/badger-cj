package badgercj.db

import std.collection.*
import badgercj.table.*

/**
 * MemTableIterator - MemTable 迭代器包装器
 * 
 * 将 SkipIterator 包装成 SimpleIterator 接口
 */
public class MemTableIterator <: SimpleIterator {
    private let mt: MemTable
    private var skipIter: SkipIterator
    private var currentKey: Array<Byte>
    private var currentValue: Array<Byte>
    private var valid_: Bool
    
    public init(mt: MemTable) {
        super()
        this.mt = mt
        this.skipIter = mt.iterator()
        this.currentKey = []
        this.currentValue = []
        this.valid_ = false
        
        advance()
    }
    
    public override func valid(): Bool {
        return valid_
    }
    
    public override func key(): Array<Byte> {
        return currentKey
    }
    
    public override func value(): Array<Byte> {
        return currentValue
    }
    
    public override func next(): Unit {
        advance()
    }
    
    public override func rewind(): Unit {
        // 重新创建 SkipIterator 以重置到开头
        this.skipIter = mt.iterator()
        advance()
    }
    
    public override func seek(key: Array<Byte>): Unit {
        // SkipIterator 不支持 seek，从头开始
        rewind()
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