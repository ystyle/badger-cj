package badgercj.table

import std.collection.*

/**
 * TableIndex - SSTable 索引
 * 
 * 从 TableIndex 数据解析而来
 */
public class TableIndex {
    public let offsets: ArrayList<BlockOffset>
    public let bloomFilter: Array<Byte>
    public let maxVersion: UInt64
    public let keyCount: UInt32
    public let uncompressedSize: UInt32
    public let onDiskSize: UInt32
    public let staleDataSize: UInt32
    
    public init(offsets: ArrayList<BlockOffset>, bloomFilter: Array<Byte>, maxVersion: UInt64, 
                keyCount: UInt32, uncompressedSize: UInt32, onDiskSize: UInt32, staleDataSize: UInt32) {
        this.offsets = offsets
        this.bloomFilter = bloomFilter
        this.maxVersion = maxVersion
        this.keyCount = keyCount
        this.uncompressedSize = uncompressedSize
        this.onDiskSize = onDiskSize
        this.staleDataSize = staleDataSize
    }
    
    /**
     * 从字节数组解析 TableIndex
     */
    public static func decodeFromData(data: Array<Byte>): TableIndex {
        let size = Int64(data.size)
        
        let checksumSizeOffset = size - 8
        let checksumSize = UInt32(data[checksumSizeOffset]) |
                          (UInt32(data[checksumSizeOffset + 1]) << 8) |
                          (UInt32(data[checksumSizeOffset + 2]) << 16) |
                          (UInt32(data[checksumSizeOffset + 3]) << 24)
        
        let checksumOffset = checksumSizeOffset - Int64(checksumSize)
        
        let indexSizeOffset = checksumOffset - 4
        let indexSize = UInt32(data[indexSizeOffset]) |
                       (UInt32(data[indexSizeOffset + 1]) << 8) |
                       (UInt32(data[indexSizeOffset + 2]) << 16) |
                       (UInt32(data[indexSizeOffset + 3]) << 24)
        
        let indexStart = indexSizeOffset - Int64(indexSize)
        let indexData = data[indexStart..indexSizeOffset]
        
        return decode(indexData)
    }
    
    /**
     * 从字节数组解析 TableIndex
     */
    public static func decode(data: Array<Byte>): TableIndex {
        var offset: Int64 = 0
        
        let blockCount = readUInt32(data, offset)
        offset += 4
        
        let offsets = ArrayList<BlockOffset>()
        for (_ in 0..Int64(blockCount)) {
            let keyLen = readUInt32(data, offset)
            offset += 4
            
            let key = readBytes(data, offset, Int64(keyLen))
            offset += Int64(keyLen)
            
            let blockOffset = readUInt32(data, offset)
            offset += 4
            
            let blockLen = readUInt32(data, offset)
            offset += 4
            
            offsets.add(BlockOffset(key, blockOffset, blockLen))
        }
        
        let bloomFilterLen = readUInt32(data, offset)
        offset += 4
        
        let bloomFilter = readBytes(data, offset, Int64(bloomFilterLen))
        offset += Int64(bloomFilterLen)
        
        let maxVersion = readUInt64(data, offset)
        offset += 8
        
        let keyCount = readUInt32(data, offset)
        offset += 4
        
        let uncompressedSize = readUInt32(data, offset)
        offset += 4
        
        let onDiskSize = readUInt32(data, offset)
        offset += 4
        
        let staleDataSize = readUInt32(data, offset)
        
        return TableIndex(offsets, bloomFilter, maxVersion, keyCount, uncompressedSize, onDiskSize, staleDataSize)
    }
    
    private static func readUInt32(data: Array<Byte>, offset: Int64): UInt32 {
        return UInt32(data[offset]) |
               (UInt32(data[offset + 1]) << 8) |
               (UInt32(data[offset + 2]) << 16) |
               (UInt32(data[offset + 3]) << 24)
    }
    
    private static func readUInt64(data: Array<Byte>, offset: Int64): UInt64 {
        return UInt64(data[offset]) |
               (UInt64(data[offset + 1]) << 8) |
               (UInt64(data[offset + 2]) << 16) |
               (UInt64(data[offset + 3]) << 24) |
               (UInt64(data[offset + 4]) << 32) |
               (UInt64(data[offset + 5]) << 40) |
               (UInt64(data[offset + 6]) << 48) |
               (UInt64(data[offset + 7]) << 56)
    }
    
    private static func readBytes(data: Array<Byte>, offset: Int64, len: Int64): Array<Byte> {
        return data[offset..(offset + len)]
    }
    
    /**
     * 查找包含指定 key 的 Block
     */
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
    
    private func compareKeys(a: Array<Byte>, b: Array<Byte>): Int64 {
        let minLen = if (a.size < b.size) { a.size } else { b.size }
        
        for (i in 0..minLen) {
            if (a[i] < b[i]) {
                return -1
            } else if (a[i] > b[i]) {
                return 1
            }
        }
        
        if (a.size < b.size) {
            return -1
        } else if (a.size > b.size) {
            return 1
        }
        
        return 0
    }
}
