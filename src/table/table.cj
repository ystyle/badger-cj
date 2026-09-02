package badgercj.table

import std.collection.*
import std.fs.*
import std.io.*
import badgercj.utils.{compareKeys, keysEqual, hasPrefix}
import snappy.decode

/**
 * Table - SSTable 读取器
 */
protected class Table {
    private let data: Array<Byte>
    public let id: UInt64
    public let isInMemory: Bool
    private let index: TableIndex
    private let bloomFilter: ?BloomFilter
    
    public let smallest: Array<Byte>
    public let biggest: Array<Byte>
    public let keyCount: UInt32
    public let maxVersion: UInt64
    
    public init(id: UInt64, data: Array<Byte>, inMemory!: Bool = false) {
        this.id = id
        this.data = data
        this.isInMemory = inMemory
        this.index = TableIndex.decodeFromData(data)
        
        if (index.bloomFilter.size > 0) {
            this.bloomFilter = Some(BloomFilter(index.bloomFilter))
        } else {
            this.bloomFilter = None
        }
        
        if (index.tableSmallest.size > 0) {
            this.smallest = index.tableSmallest
            this.biggest = index.tableBiggest
        } else if (index.offsets.size > 0) {
            this.smallest = index.offsets[0].key
            this.biggest = index.offsets[index.offsets.size - 1].key
        } else {
            this.smallest = []
            this.biggest = []
        }
        this.keyCount = index.keyCount
        this.maxVersion = index.maxVersion
    }
    
    public func get(key: Array<Byte>): Option<Array<Byte>> {
        if (!mayContain(key)) {
            return None
        }
        
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
    
    public func mayContain(key: Array<Byte>): Bool {
        match (bloomFilter) {
            case Some(bf) => bf.mayContain(key)
            case None => true
        }
    }
    
    public func hasBloomFilter(): Bool {
        bloomFilter.isSome()
    }
    
    public func bloomFilterSize(): Int64 {
        match (bloomFilter) {
            case Some(bf) => bf.size()
            case None => 0
        }
    }
    
    public func newIterator(): TableIter {
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
        let blockData = data[Int64(bo.offset)..Int64(bo.offset + bo.len)]
        
        // 解压 Block
        if (bo.compression == CompressionType.Snappy) {
            return decompressBlock(blockData)
        }
        return blockData
    }
    
    private func decompressBlock(compressed: Array<Byte>): Array<Byte> {
        let dst = Array<Byte>(compressed.size * 4, repeat: 0)  // 预估解压后大小
        decode(dst, compressed)
    }
    
    public func findBlock(key: Array<Byte>): Int64 {
        if (index.offsets.size == 0) {
            return -1
        }
        
        var left: Int64 = 0
        var right: Int64 = index.offsets.size - 1
        
        while (left < right) {
            let mid = (left + right) / 2
            let cmp = compareKeys(key, index.offsets[mid].key)
            
            if (cmp > 0) {
                left = mid + 1
            } else {
                right = mid
            }
        }
        
        let cmp = compareKeys(key, index.offsets[left].key)
        if (cmp >= 0 || left == 0) {
            return left
        }
        
        // R3 修复：key < 块首 且与块首同属一个 user key（块首即该组首条 = 最大版本）。
        // 此时 key 是「readTs ≥ 组内最大存储版本」的 seek（keyWithTs 编码 ts 取反降序，
        // 更大 ts 排更前）——key 实际仍落在该块的 user key 组内（组首条 ≤ readTs 可命中），
        // 必须返回本块而非回退前一块（回退会在前一块内 seek 到块尾而稳定 miss）。
        if (sameUserKey(key, index.offsets[left].key)) {
            return left
        }
        
        return left - 1
    }
    
    // 比较两个带 ts 的存储 key 是否同属一个 user key（去掉尾部 8 字节 ts 后相等）
    private func sameUserKey(a: Array<Byte>, b: Array<Byte>): Bool {
        if (a.size <= 8 || b.size <= 8) {
            return false
        }
        let alen = a.size - 8
        let blen = b.size - 8
        if (alen != blen) {
            return false
        }
        for (i in 0..alen) {
            if (a[i] != b[i]) {
                return false
            }
        }
        true
    }
    
    public func onDiskSize(): Int64 {
        Int64(data.size)
    }
    
    public func uncompressedSize(): Int64 {
        Int64(data.size)
    }
    
    public func offsetsLength(): Int64 {
        index.offsets.size
    }
    
    public func getOffsetKey(idx: Int64): Array<Byte> {
        if (idx < 0 || idx >= index.offsets.size) {
            return []
        }
        index.offsets[idx].key
    }
    
    public func keySplits(n: Int64, prefix: Array<Byte>): ArrayList<Array<Byte>> {
        let result = ArrayList<Array<Byte>>()
        if (n <= 0) {
            return result
        }
        
        let oLen = index.offsets.size
        var jump = oLen / n
        if (jump == 0) {
            jump = 1
        }
        
        var i: Int64 = 0
        while (i < oLen) {
            let key = getOffsetKey(i)
            if (hasPrefix(key, prefix)) {
                result.add(key)
            }
            i += jump
        }
        
        result
    }
}