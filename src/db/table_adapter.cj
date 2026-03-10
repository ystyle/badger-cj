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
        let result = table.get(key)
        match (result) {
            case Some(data) => return Some(ValueStruct(data, version: readTs))
            case None => return None
        }
    }
    
    public func size(): Int64 {
        Int64(table.keyCount)
    }
}
