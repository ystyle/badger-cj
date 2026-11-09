package badgercj.table

import std.collection.*

/**
 * TableIterator - Table 迭代器
 */
protected class TableIterator <: TableIter {
    private let table: Table
    private var blockIdx: Int64
    private var blockIter: BlockIterator
    private var closed: Bool
    
    public init(table: Table) {
        this.table = table
        this.blockIdx = 0
        this.blockIter = BlockIterator([], [])
        this.closed = false
        seekFirst()
    }
    
    /** 关闭：归还表引用（Table.newIterator 里取的），幂等。 */
    public func close(): Unit {
        if (closed) {
            return
        }
        closed = true
        table.decrRef()
    }
    
    public func seekFirst(): Unit {
        blockIdx = 0
        if (table.numBlocks() > 0) {
            blockIter = table.blockIterator(0)
            blockIter.seekToFirst()
        }
    }
    
    public func seekLast(): Unit {
        blockIdx = table.numBlocks() - 1
        if (blockIdx >= 0) {
            blockIter = table.blockIterator(blockIdx)
            blockIter.seekToLast()
        }
    }
    
    public func seek(key: Array<Byte>): Unit {
        blockIdx = table.findBlock(key)
        if (blockIdx >= 0 && blockIdx < table.numBlocks()) {
            blockIter = table.blockIterator(blockIdx)
            blockIter.seek(key)
            // findBlock 只按「块首 key」定位：key 落在前一块末尾与下一块首之间时
            // 会被指到前一块，块内二分 miss（块内全部 < key）而 invalid——
            // 但 ≥ key 的最小条目在下一块首。正向推进到下一块首；
            // reverse 场景由上层（TableIterWrapper.seek）对 > key 的结果 prev 收尾，
            // 落在上一块末尾恰好是 reverse 想要的 ≤ key 最后一条，同样受益。
            if (!blockIter.isValid() && blockIdx + 1 < table.numBlocks()) {
                blockIdx++
                blockIter = table.blockIterator(blockIdx)
                blockIter.seekToFirst()
            }
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
    
    public func prev(): Unit {
        blockIter.prev()
        if (!blockIter.isValid()) {
            blockIdx--
            if (blockIdx >= 0) {
                blockIter = table.blockIterator(blockIdx)
                blockIter.seekToLast()
            }
        }
    }
    
    public func isValid(): Bool {
        return !closed && blockIdx < table.numBlocks() && blockIter.isValid()
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