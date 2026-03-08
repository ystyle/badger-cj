package badgercj.db

import std.collection.*
import badgercj.table.*

/**
 * TableIteratorWrapper - Table 迭代器包装器
 * 
 * 将 table.TableIterator 包装成统一接口
 */
public class TableIteratorWrapper {
    private let tableIter: badgercj.table.TableIterator
    private var currentKey: Array<Byte>
    private var currentValue: Array<Byte>
    private var valid_: Bool
    
    public init(table: Table) {
        this.tableIter = table.newIterator()
        this.currentKey = []
        this.currentValue = []
        this.valid_ = false
        
        tableIter.seekToFirst()
        updateCurrent()
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
        tableIter.next()
        updateCurrent()
    }
    
    public func rewind(): Unit {
        tableIter.seekToFirst()
        updateCurrent()
    }
    
    public func seek(key: Array<Byte>): Unit {
        tableIter.seek(key)
        updateCurrent()
    }
    
    private func updateCurrent(): Unit {
        if (tableIter.isValid()) {
            currentKey = tableIter.key()
            currentValue = tableIter.value()
            valid_ = true
        } else {
            valid_ = false
        }
    }
}