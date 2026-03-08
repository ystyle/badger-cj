package badgercj.table

import std.collection.*
import std.fs.*
import std.io.*

/**
 * Table - SSTable 读取器
 */
public class Table {
    private let data: Array<Byte>
    private let id: UInt64
    private let index: TableIndex
    
    public let smallest: Array<Byte>
    public let biggest: Array<Byte>
    public let keyCount: UInt32
    
    public init(id: UInt64, data: Array<Byte>) {
        this.id = id
        this.data = data
        this.index = TableIndex.decode(data)
        
        if (index.offsets.size > 0) {
            this.smallest = index.offsets[0].key
            this.biggest = index.offsets[index.offsets.size - 1].key
        } else {
            this.smallest = []
            this.biggest = []
        }
        this.keyCount = index.keyCount
    }
    
    public func get(key: Array<Byte>): Option<Array<Byte>> {
        let idx = findBlock(key)
        if (idx < 0) {
            return None
        }
        
        let block = readBlock(idx)
        let iter = BlockIterator(block, index.offsets[idx].key)
        iter.seek(key)
        
        if (iter.isValid() && keysEqual(iter.key(), key)) {
            return Some(iter.value())
        }
        return None
    }
    
    public func newIterator(): TableIterator {
        return TableIterator(this)
    }
    
    public func numBlocks(): Int64 {
        return index.offsets.size
    }
    
    public func blockIterator(idx: Int64): BlockIterator {
        let block = readBlock(idx)
        return BlockIterator(block, index.offsets[idx].key)
    }
    
    private func readBlock(idx: Int64): Array<Byte> {
        let bo = index.offsets[idx]
        return data[Int64(bo.offset)..Int64(bo.offset + bo.len)]
    }
    
    public func findBlock(key: Array<Byte>): Int64 {
        var left: Int64 = 0
        var right: Int64 = index.offsets.size - 1
        
        while (left <= right) {
            let mid = (left + right) / 2
            let cmp = compareKeys(key, index.offsets[mid].key)
            
            if (cmp == 0) {
                return mid
            } else if (cmp < 0) {
                right = mid - 1
            } else {
                left = mid + 1
            }
        }
        
        if (left > 0) {
            return left - 1
        }
        return -1
    }
    
    private func compareKeys(a: Array<Byte>, b: Array<Byte>): Int64 {
        let minLen = if (a.size < b.size) { a.size } else { b.size }
        for (i in 0..minLen) {
            if (a[i] != b[i]) {
                return Int64(a[i]) - Int64(b[i])
            }
        }
        return Int64(a.size) - Int64(b.size)
    }
    
    private func keysEqual(a: Array<Byte>, b: Array<Byte>): Bool {
        if (a.size != b.size) {
            return false
        }
        for (i in 0..a.size) {
            if (a[i] != b[i]) {
                return false
            }
        }
        return true
    }
}