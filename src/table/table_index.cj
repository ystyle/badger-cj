package badgercj.table

import std.collection.*

/**
 * TableIndex - SSTable 索引
 * 
 * 从 TableIndex 数据解析而来
 */
public class TableIndex {
    public let offsets: ArrayList<BlockOffset>
    public let maxVersion: UInt64
    public let keyCount: UInt32
    public let uncompressedSize: UInt32
    public let onDiskSize: UInt32
    public let staleDataSize: UInt32
    
    public init(offsets: ArrayList<BlockOffset>, maxVersion: UInt64, keyCount: UInt32,
                uncompressedSize: UInt32, onDiskSize: UInt32, staleDataSize: UInt32) {
        this.offsets = offsets
        this.maxVersion = maxVersion
        this.keyCount = keyCount
        this.uncompressedSize = uncompressedSize
        this.onDiskSize = onDiskSize
        this.staleDataSize = staleDataSize
    }
    
    /**
     * 从字节数组解析 TableIndex
     */
    public static func decode(data: Array<Byte>): TableIndex {
        var offset: Int64 = 0
        
        let blockCount = readUInt32(data, offset)
        offset += 4
        
        let offsets = ArrayList<BlockOffset>()
        var off: Int64 = 0
        for (_ in 0..Int64(blockCount)) {
            let keyLen = readUInt32(data, off)
            off += 4
            
            let key = readBytes(data, off, Int64(keyLen))
            off += Int64(keyLen)
            
            let blockOffset = readUInt32(data, off)
            off += 4
            
            let blockLen = readUInt32(data, off)
            off += 4
            
            offsets.add(BlockOffset(key, blockOffset, blockLen))
        }
        
        let bloomFilterLen = readUInt32(data, off)
        off += 4
        off += Int64(bloomFilterLen)
        
        let maxVersion = readUInt64(data, off)
        off += 8
        
        let keyCount = readUInt32(data, off)
        off += 4
        
        let uncompressedSize = readUInt32(data, off)
        off += 4
        
        let onDiskSize = readUInt32(data, off)
        off += 4
        
        let staleDataSize = readUInt32(data, off)
        
        return TableIndex(offsets, maxVersion, keyCount, uncompressedSize, onDiskSize, staleDataSize)
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
