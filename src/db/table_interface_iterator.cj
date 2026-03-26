package badgercj.db

import std.collection.*
import badgercj.table.*

/**
 * TableInterfaceIterator - 包装迭代器为 SimpleIterator
 */
public class TableInterfaceIterator <: SimpleIterator {
    private let tableIter: TableIter
    private let table: TableInterface
    private var useIter: Bool
    
    public init(table: TableInterface) {
        super()
        this.table = table
        this.tableIter = EmptyTableIter()
        this.useIter = false
    }
    
    public init(tableIter: TableIter) {
        super()
        this.tableIter = tableIter
        this.table = TableAdapter(Table(0, []))
        this.useIter = true
    }
    
    public override func valid(): Bool {
        if (useIter) {
            return tableIter.isValid()
        }
        let vs = table.get(table.smallest(), 0)
        vs.isSome()
    }
    
    public override func key(): Array<Byte> {
        if (useIter) {
            return tableIter.key()
        }
        return table.smallest()
    }
    
    public override func value(): Array<Byte> {
        if (useIter) {
            return tableIter.value()
        }
        if (let Some(vs) <- table.get(table.smallest(), 0)) {
            return vs.value
        }
        return []
    }
    
    public override func next(): Unit {
        if (useIter) {
            tableIter.next()
        }
    }
    
    public override func rewind(): Unit {
        if (useIter) {
            tableIter.seekFirst()
        }
    }
    
    public override func seek(key: Array<Byte>): Unit {
        if (useIter) {
            tableIter.seek(key)
        }
    }
}

class EmptyTableIter <: TableIter {
    public func seekFirst(): Unit {}
    public func seekLast(): Unit {}
    public func seek(key: Array<Byte>): Unit {}
    public func next(): Unit {}
    public func prev(): Unit {}
    public func isValid(): Bool { false }
    public func key(): Array<Byte> { [] }
    public func value(): Array<Byte> { [] }
    public func valueStruct(): ?ValueStruct { None }
}