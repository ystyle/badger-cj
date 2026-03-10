package badgercj.db

import std.collection.*
import badgercj.table.*

public class TableAdapter <: TableInterface {
    private let table: Table
    
    public init(table: Table) {
        this.table = table
    }
    
    public func getId(): UInt64 {
        return table.id
    }
    
    public func smallest(): Array<Byte> {
        table.smallest
    }
    
    public func biggest(): Array<Byte> {
        table.biggest
    }
    
    public func get(key: Array<Byte>, readTs: UInt64): Option<ValueStruct> {
        let seekKey = keyWithTs(key, readTs)
        
        let idx = table.findBlock(seekKey)
        if (idx < 0) {
            return None
        }
        
        let iter = table.blockIterator(idx)
        iter.seek(seekKey)
        
        while (iter.isValid()) {
            let iterKey = iter.key()
            if (sameKey(iterKey, key)) {
                let ts = parseTs(iterKey)
                if (ts <= readTs) {
                    if (let Some(vs) <- iter.valueStruct()) {
                        return Some(vs)
                    }
                }
            } else {
                break
            }
            iter.next()
        }
        
        return None
    }
    
    public func size(): Int64 {
        Int64(table.keyCount)
    }
    
    public func getMaxVersion(): UInt64 {
        table.maxVersion
    }
}
