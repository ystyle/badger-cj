package badgercj.db

import std.collection.*
import badgercj.table.*

public class TableInterfaceIterator <: SimpleIterator {
    private let table: TableInterface
    private var currentKey: Array<Byte>
    private var currentValue: Array<Byte>
    private var valid_: Bool
    
    public init(table: TableInterface) {
        super()
        this.table = table
        this.currentKey = table.smallest()
        this.currentValue = []
        this.valid_ = true
        
        updateValue(currentKey)
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
        valid_ = false
    }
    
    public override func rewind(): Unit {
        currentKey = table.smallest()
        updateValue(currentKey)
    }
    
    public override func seek(key: Array<Byte>): Unit {
        currentKey = key
        updateValue(key)
    }
    
    private func updateValue(key: Array<Byte>): Unit {
        let vs = table.get(key, 0)
        if (let Some(v) <- vs) {
            currentValue = v.value
            valid_ = true
        } else {
            valid_ = false
        }
    }
}
