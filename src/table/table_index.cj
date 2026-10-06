package badgercj.table

import std.collection.*
import badgercj.utils.{compareKeys, u32FromLE, u64FromLE}

/**
 * TableIndex - SSTable 索引
 * 
 * 从 TableIndex 数据解析而来
 */
protected class TableIndex {
    public let offsets: ArrayList<BlockOffset>
    public let bloomFilter: Array<Byte>
    public let maxVersion: UInt64
    public let keyCount: UInt32
    public let uncompressedSize: UInt32
    public let onDiskSize: UInt32
    public let staleDataSize: UInt32
    public let tableSmallest: Array<Byte>
    public let tableBiggest: Array<Byte>
    
    public init(offsets: ArrayList<BlockOffset>, bloomFilter: Array<Byte>, maxVersion: UInt64, 
                keyCount: UInt32, uncompressedSize: UInt32, onDiskSize: UInt32, staleDataSize: UInt32,
                tableSmallest!: Array<Byte> = [], tableBiggest!: Array<Byte> = []) {
        this.offsets = offsets
        this.bloomFilter = bloomFilter
        this.maxVersion = maxVersion
        this.keyCount = keyCount
        this.uncompressedSize = uncompressedSize
        this.onDiskSize = onDiskSize
        this.staleDataSize = staleDataSize
        this.tableSmallest = tableSmallest
        this.tableBiggest = tableBiggest
    }
    
    /**
     * 从字节数组解析 TableIndex
     */
    public static func decodeFromData(data: Array<Byte>): TableIndex {
        let size = Int64(data.size)
        
        if (size < 12) {
            return TableIndex(ArrayList<BlockOffset>(), [], 0, 0, 0, 0, 0)
        }
        
        let checksumSize = UInt32(data[size - 4]) |
                          (UInt32(data[size - 3]) << 8) |
                          (UInt32(data[size - 2]) << 16) |
                          (UInt32(data[size - 1]) << 24)
        
        let checksumEnd = size - 4
        let checksumStart = checksumEnd - Int64(checksumSize)
        
        if (checksumStart < 4) {
            return TableIndex(ArrayList<BlockOffset>(), [], 0, 0, 0, 0, 0)
        }
        
        let indexSizeEnd = checksumStart
        let indexSize = UInt32(data[indexSizeEnd - 4]) |
                       (UInt32(data[indexSizeEnd - 3]) << 8) |
                       (UInt32(data[indexSizeEnd - 2]) << 16) |
                       (UInt32(data[indexSizeEnd - 1]) << 24)
        
        let indexEnd = indexSizeEnd - 4
        let indexStart = indexEnd - Int64(indexSize)
        
        if (indexStart < 0 || indexEnd > size) {
            return TableIndex(ArrayList<BlockOffset>(), [], 0, 0, 0, 0, 0)
        }
        
        let indexData = data[indexStart..indexEnd]
        
        return decode(indexData)
    }
    
    /**
     * 从 TableData 按需解析索引：只读取文件尾部的三段（末尾 4B 的 crc 长度、
     * 其前的 indexSize、以及 index 本体），**不把整张表读进内存**。
     * 磁盘模式下这正是「表数据移出 GC 堆」的关键——索引很小，数据块不读。
     */
    public static func decodeFromTableData(td: TableData): TableIndex {
        let size = td.size()
        if (size < 12) {
            return TableIndex(ArrayList<BlockOffset>(), [], 0, 0, 0, 0, 0)
        }

        let tail = td.read(size - 4, 4)
        let checksumSize = u32FromLE(tail, 0)

        let checksumEnd = size - 4
        let checksumStart = checksumEnd - Int64(checksumSize)
        if (checksumStart < 4) {
            return TableIndex(ArrayList<BlockOffset>(), [], 0, 0, 0, 0, 0)
        }

        let lenBytes = td.read(checksumStart - 4, 4)
        let indexSize = u32FromLE(lenBytes, 0)

        let indexEnd = checksumStart - 4
        let indexStart = indexEnd - Int64(indexSize)
        if (indexStart < 0 || indexEnd > size) {
            return TableIndex(ArrayList<BlockOffset>(), [], 0, 0, 0, 0, 0)
        }

        let indexData = td.read(indexStart, Int64(indexSize))
        return decode(indexData)
    }

    /**
     * 从字节数组解析 TableIndex
     */
    public static func decode(data: Array<Byte>): TableIndex {
        var offset: Int64 = 0
        
        let smallestLen = u32FromLE(data, offset)
        offset += 4
        let tableSmallest = data[offset..(offset + Int64(smallestLen))]
        offset += Int64(smallestLen)
        
        let biggestLen = u32FromLE(data, offset)
        offset += 4
        let tableBiggest = data[offset..(offset + Int64(biggestLen))]
        offset += Int64(biggestLen)
        
        let blockCount = u32FromLE(data, offset)
        offset += 4
        
        let offsets = ArrayList<BlockOffset>()
        for (_ in 0..Int64(blockCount)) {
            let keyLen = u32FromLE(data, offset)
            offset += 4
            
            let key = data[offset..(offset + Int64(keyLen))]
            offset += Int64(keyLen)
            
            let blockOffset = u32FromLE(data, offset)
            offset += 4
            
            let blockLen = u32FromLE(data, offset)
            offset += 4
            
            let compression = if (data[offset] == 1) { CompressionType.Snappy } else { CompressionType.None }
            offset += 1
            
            offsets.add(BlockOffset(key, blockOffset, blockLen, compression: compression))
        }
        
        let bloomFilterLen = u32FromLE(data, offset)
        offset += 4
        
        let bloomFilter = data[offset..(offset + Int64(bloomFilterLen))]
        offset += Int64(bloomFilterLen)
        
        let maxVersion = u64FromLE(data, offset)
        offset += 8
        
        let keyCount = u32FromLE(data, offset)
        offset += 4
        
        let uncompressedSize = u32FromLE(data, offset)
        offset += 4
        
        let onDiskSize = u32FromLE(data, offset)
        offset += 4
        
        let staleDataSize = u32FromLE(data, offset)
        
        return TableIndex(offsets, bloomFilter, maxVersion, keyCount, uncompressedSize, onDiskSize, staleDataSize,
            tableSmallest: tableSmallest, tableBiggest: tableBiggest)
    }
    
    public func seekBlock(key: Array<Byte>): Option<UInt32> {
        var idx: Int64 = 0
        for (i in 0..offsets.size) {
            if (compareKeys(key, offsets[i].key) < 0) {
                break
            }
            idx = i
        }
        
        if (idx >= offsets.size) {
            return None
        }
        
        return Some(UInt32(idx))
    }
}
