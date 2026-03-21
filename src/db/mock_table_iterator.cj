package badgercj.db

import std.collection.*
import badgercj.table.*
import badgercj.utils.compareKeys

/**
 * MockTableIterator - MockTable 迭代器包装器
 * 
 * 将 MockTable 包装成 SimpleIterator 接口
 */
public class MockTableIterator <: SimpleIterator {
    private let entries: ArrayList<(Array<Byte>, ValueStruct)>
    private var currentIndex: Int64
    private var currentKey: Array<Byte>
    private var currentValue: Array<Byte>
    private var valid_: Bool
    
    public init(table: MockTable) {
        super()
        this.entries = ArrayList<(Array<Byte>, ValueStruct)>()
        
        let tableEntries = table.getEntries()
        for (entry in tableEntries) {
            this.entries.add(entry)
        }
        
        this.currentIndex = -1
        this.currentKey = []
        this.currentValue = []
        this.valid_ = false
        
        rewind()
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
        currentIndex++
        updateCurrent()
    }
    
    public override func rewind(): Unit {
        currentIndex = 0
        updateCurrent()
    }
    
    public override func seek(key: Array<Byte>): Unit {
        currentIndex = 0
        for (i in 0..entries.size) {
            if (compareKeys(entries[i][0], key) >= 0) {
                currentIndex = i
                break
            }
        }
        updateCurrent()
    }
    
    private func updateCurrent(): Unit {
        if (currentIndex >= 0 && currentIndex < entries.size) {
            let entry = entries[currentIndex]
            currentKey = entry[0]
            currentValue = entry[1].value
            valid_ = true
        } else {
            currentKey = []
            currentValue = []
            valid_ = false
        }
    }
}