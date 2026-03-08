package badgercj.table

import std.collection.*
import badgercj.encoding.*

/**
 * BlockBuilder - 构建 SSTable Block
 * 
 * 使用前缀压缩减少 key 的存储空间
 * 参考：github.com/dgraph-io/badger/v4/table/builder.go
 */
public class BlockBuilder {
    private let blockSize: Int64
    private var buf: ArrayList<Byte>
    private var baseKey: Array<Byte>
    private var entryOffsets: ArrayList<UInt32>
    private var tableKeyCount: UInt32
    private var finished: Bool
    
    public init(blockSize!: Int64 = 4 * 1024) {
        this.blockSize = blockSize
        this.buf = ArrayList<Byte>()
        this.baseKey = []
        this.entryOffsets = ArrayList<UInt32>()
        this.tableKeyCount = 0
        this.finished = false
    }
    
    /**
     * 添加 key-value 对到 Block
     * 
     * 返回：是否成功添加（如果 Block 已满返回 false）
     */
    public func add(key: Array<Byte>, value: ValueStruct): Bool {
        if (finished) {
            throw Exception("BlockBuilder already finished")
        }
        
        if (shouldCreateNewBlock(key)) {
            return false
        }
        
        let diffKey: Array<Byte>
        let overlap: UInt16
        let diffLen: UInt16
        
        if (baseKey.size == 0) {
            baseKey = key
            diffKey = key
            overlap = 0
            diffLen = UInt16(key.size)
        } else {
            let overlapLen = computeOverlap(baseKey, key)
            overlap = UInt16(overlapLen)
            diffLen = UInt16(key.size - overlapLen)
            diffKey = key[overlapLen..]
        }
        
        entryOffsets.add(UInt32(buf.size))
        
        buf.add(UInt8(overlap & 0xFF))
        buf.add(UInt8((overlap >> 8) & 0xFF))
        buf.add(UInt8(diffLen & 0xFF))
        buf.add(UInt8((diffLen >> 8) & 0xFF))
        
        for (b in diffKey) {
            buf.add(b)
        }
        
        let encodedValue = value.encode()
        for (b in encodedValue) {
            buf.add(b)
        }
        
        tableKeyCount++
        return true
    }
    
    private func shouldCreateNewBlock(key: Array<Byte>): Bool {
        if (buf.size == 0) {
            return false
        }
        
        let estimatedSize = 4 + key.size + 16 + 100
        return (buf.size + estimatedSize + 4 * (entryOffsets.size + 1) + 4 + 8) > blockSize && entryOffsets.size > 0
    }
    
    private func computeOverlap(a: Array<Byte>, b: Array<Byte>): Int64 {
        let minLen = if (a.size < b.size) { a.size } else { b.size }
        var i: Int64 = 0
        
        while (i < minLen && a[i] == b[i]) {
            i++
        }
        
        return i
    }
    
    /**
     * 完成 Block 构建并返回字节数组
     */
    public func finish(): Array<Byte> {
        if (finished) {
            throw Exception("BlockBuilder already finished")
        }
        
        finished = true
        
let numEntries = UInt32(entryOffsets.size)
        for (i in 0..Int64(numEntries)) {
            let offset = entryOffsets[Int64(numEntries) - 1 - i]
            buf.add(UInt8(offset & 0xFF))
            buf.add(UInt8((offset >> 8) & 0xFF))
            buf.add(UInt8((offset >> 16) & 0xFF))
            buf.add(UInt8((offset >> 24) & 0xFF))
        }
        
        buf.add(UInt8(numEntries & 0xFF))
        buf.add(UInt8((numEntries >> 8) & 0xFF))
        buf.add(UInt8((numEntries >> 16) & 0xFF))
        buf.add(UInt8((numEntries >> 24) & 0xFF))
        
        let data = buf.toArray()
        let crc = CRC32C()
        crc.write(data)
        let checksum = crc.sum32()
        
        let result = ArrayList<Byte>()
        for (b in data) {
            result.add(b)
        }
        
        result.add(UInt8(checksum & 0xFF))
        result.add(UInt8((checksum >> 8) & 0xFF))
        result.add(UInt8((checksum >> 16) & 0xFF))
        result.add(UInt8((checksum >> 24) & 0xFF))
        
        result.add(4)
        result.add(0)
        result.add(0)
        result.add(0)
        
        return result.toArray()
    }
    
    public func size(): Int64 {
        return buf.size
    }
    
    public func isEmpty(): Bool {
        return buf.size == 0
    }
    
    public func getKeyCount(): UInt32 {
        return tableKeyCount
    }
    
    public func getBaseKey(): Array<Byte> {
        return baseKey
    }
    
    public func reset(): Unit {
        buf.clear()
        baseKey = []
        entryOffsets.clear()
        tableKeyCount = 0
        finished = false
    }
}