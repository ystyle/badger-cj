package badgercj.db

import std.collection.*
import badgercj.table.*

/**
 * TableIteratorWrapper - Table 迭代器包装器
 * 
 * 将 table.TableIterator 包装成统一接口
 */
public class TableIteratorWrapper <: SimpleIterator {
    private let tableIter: TableIter
    private var currentKey: Array<Byte>
    private var currentValue: Array<Byte>
    private var valid_: Bool
    
    protected init(table: Table) {
        super()
        this.tableIter = table.newIterator()
        this.currentKey = []
        this.currentValue = []
        this.valid_ = false
        
        tableIter.seekFirst()
        updateCurrent()
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
        tableIter.next()
        updateCurrent()
    }
    
    public override func rewind(): Unit {
        tableIter.seekFirst()
        updateCurrent()
    }
    
    public override func seek(key: Array<Byte>): Unit {
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