package badgercj.table

import std.collection.*

/**
 * TableIterator - Table 迭代器
 */
protected class TableIterator {
    private let table: Table
    private var blockIdx: Int64
    private var blockIter: BlockIterator
    
    public init(table: Table) {
        this.table = table
        this.blockIdx = 0
        this.blockIter = BlockIterator([], [])
        seekToFirst()
    }
    
    public func seekToFirst(): Unit {
        blockIdx = 0
        if (table.numBlocks() > 0) {
            blockIter = table.blockIterator(0)
            blockIter.seekToFirst()
        }
    }
    
    public func seek(key: Array<Byte>): Unit {
        blockIdx = table.findBlock(key)
        if (blockIdx >= 0 && blockIdx < table.numBlocks()) {
            blockIter = table.blockIterator(blockIdx)
            blockIter.seek(key)
        }
    }
    
    public func next(): Unit {
        blockIter.next()
        if (!blockIter.isValid()) {
            blockIdx++
            if (blockIdx < table.numBlocks()) {
                blockIter = table.blockIterator(blockIdx)
                blockIter.seekToFirst()
            }
        }
    }
    
    public func isValid(): Bool {
        return blockIdx < table.numBlocks() && blockIter.isValid()
    }
    
    public func key(): Array<Byte> {
        return blockIter.key()
    }
    
    public func value(): Array<Byte> {
        return blockIter.value()
    }
    
    public func valueStruct(): ?ValueStruct {
        return blockIter.valueStruct()
    }
}