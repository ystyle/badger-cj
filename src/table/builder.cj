package badgercj.table

import std.collection.*
import badgercj.encoding.*

/**
 * TableBuilder - 构建 SSTable 文件
 * 
 * 参考：github.com/dgraph-io/badger/v4/table/builder.go
 * 
 * SSTable 文件格式：
 * ┌─────────────────────────────────────────┐
 * │  Block 1                                │
 * │  Block 2                                │
 * │  ...                                    │
 * │  Block N                                │
 * ├─────────────────────────────────────────┤
 * │  Table Index (FlatBuffers compatible)  │
 * │  Index Size (4 bytes)                  │
 * ├─────────────────────────────────────────┤
 * │  Checksum (CRC32, 4 bytes)             │
 * │  Checksum Size (4 bytes)               │
 * └─────────────────────────────────────────┘
 */
public class TableBuilder {
    private let blockSize: Int64
    private let bloomFalsePositive: Float64
    private var currentBlock: BlockBuilder
    private var buf: ArrayList<Byte>
    private var blockOffsets: ArrayList<BlockOffset>
    private var keyHashes: ArrayList<UInt32>
    private var keyCount: UInt32
    private var maxVersion: UInt64
    private var uncompressedSize: UInt32
    private var finished: Bool
    private var tableSmallest: Array<Byte>
    private var tableBiggest: Array<Byte>
    
    public init(blockSize!: Int64 = 4 * 1024, bloomFalsePositive!: Float64 = 0.01) {
        this.blockSize = blockSize
        this.bloomFalsePositive = bloomFalsePositive
        this.currentBlock = BlockBuilder(blockSize: blockSize)
        this.buf = ArrayList<Byte>()
        this.blockOffsets = ArrayList<BlockOffset>()
        this.keyHashes = ArrayList<UInt32>()
        this.keyCount = 0
        this.maxVersion = 0
        this.uncompressedSize = 0
        this.finished = false
        this.tableSmallest = []
        this.tableBiggest = []
    }
    
    /**
     * 添加 key-value 对
     */
    public func add(key: Array<Byte>, value: ValueStruct): Unit {
        if (finished) {
            throw Exception("TableBuilder already finished")
        }
        
        if (tableSmallest.size == 0 || compareKeys(key, tableSmallest) < 0) {
            tableSmallest = key
        }
        if (tableBiggest.size == 0 || compareKeys(key, tableBiggest) > 0) {
            tableBiggest = key
        }
        
        if (!currentBlock.add(key, value)) {
            finishBlock()
            
            if (!currentBlock.add(key, value)) {
                throw Exception("Key too large for block: ${key.size} bytes")
            }
        }
        
        if (bloomFalsePositive > 0.0) {
            keyHashes.add(BloomFilter.hash(key))
        }
        
        keyCount++
        uncompressedSize += UInt32(key.size + value.value.size)
        
        if (value.version > maxVersion) {
            maxVersion = value.version
        }
    }
    
    /**
     * 完成当前 Block
     */
    private func finishBlock(): Unit {
        if (currentBlock.isEmpty()) {
            return
        }
        
        let blockData = currentBlock.finish()
        let offset = UInt32(buf.size)
        
        let blockOffset = BlockOffset(currentBlock.getBaseKey(), offset, UInt32(blockData.size))
        blockOffsets.add(blockOffset)
        
        for (b in blockData) {
            buf.add(b)
        }
        
        currentBlock.reset()
    }
    
    /**
     * 完成 SSTable 构建并返回字节数组
     */
    public func finish(): Array<Byte> {
        if (finished) {
            throw Exception("TableBuilder already finished")
        }
        
        finished = true
        finishBlock()
        
        let indexData = buildTableIndex()
        
        for (b in indexData) {
            buf.add(b)
        }
        
        let indexSize = UInt32(indexData.size)
        buf.add(UInt8(indexSize & 0xFF))
        buf.add(UInt8((indexSize >> 8) & 0xFF))
        buf.add(UInt8((indexSize >> 16) & 0xFF))
        buf.add(UInt8((indexSize >> 24) & 0xFF))
        
        let data = buf.toArray()
        let crc = CRC32C()
        crc.write(data)
        let checksum = crc.sum32()
        
        buf.add(UInt8(checksum & 0xFF))
        buf.add(UInt8((checksum >> 8) & 0xFF))
        buf.add(UInt8((checksum >> 16) & 0xFF))
        buf.add(UInt8((checksum >> 24) & 0xFF))
        
        buf.add(4)
        buf.add(0)
        buf.add(0)
        buf.add(0)
        
        return buf.toArray()
    }
    
    /**
     * 构建 Table Index (手动实现 FlatBuffers 兼容格式)
     * 
     * FlatBuffers TableIndex 结构：
     * - offsets: [BlockOffset]
     * - bloom_filter: [ubyte]
     * - max_version: uint64
     * - key_count: uint32
     * - uncompressed_size: uint32
     * - on_disk_size: uint32
     * - stale_data_size: uint32
     */
    private func buildTableIndex(): Array<Byte> {
        let indexBuf = ArrayList<Byte>()
        
        let smallestLen = UInt32(tableSmallest.size)
        indexBuf.add(UInt8(smallestLen & 0xFF))
        indexBuf.add(UInt8((smallestLen >> 8) & 0xFF))
        indexBuf.add(UInt8((smallestLen >> 16) & 0xFF))
        indexBuf.add(UInt8((smallestLen >> 24) & 0xFF))
        for (b in tableSmallest) {
            indexBuf.add(b)
        }
        
        let biggestLen = UInt32(tableBiggest.size)
        indexBuf.add(UInt8(biggestLen & 0xFF))
        indexBuf.add(UInt8((biggestLen >> 8) & 0xFF))
        indexBuf.add(UInt8((biggestLen >> 16) & 0xFF))
        indexBuf.add(UInt8((biggestLen >> 24) & 0xFF))
        for (b in tableBiggest) {
            indexBuf.add(b)
        }
        
        let blockCount = UInt32(blockOffsets.size)
        indexBuf.add(UInt8(blockCount & 0xFF))
        indexBuf.add(UInt8((blockCount >> 8) & 0xFF))
        indexBuf.add(UInt8((blockCount >> 16) & 0xFF))
        indexBuf.add(UInt8((blockCount >> 24) & 0xFF))
        
        for (bo in blockOffsets) {
            let keyLen = UInt32(bo.key.size)
            indexBuf.add(UInt8(keyLen & 0xFF))
            indexBuf.add(UInt8((keyLen >> 8) & 0xFF))
            indexBuf.add(UInt8((keyLen >> 16) & 0xFF))
            indexBuf.add(UInt8((keyLen >> 24) & 0xFF))
            
            for (b in bo.key) {
                indexBuf.add(b)
            }
            
            indexBuf.add(UInt8(bo.offset & 0xFF))
            indexBuf.add(UInt8((bo.offset >> 8) & 0xFF))
            indexBuf.add(UInt8((bo.offset >> 16) & 0xFF))
            indexBuf.add(UInt8((bo.offset >> 24) & 0xFF))
            
            indexBuf.add(UInt8(bo.len & 0xFF))
            indexBuf.add(UInt8((bo.len >> 8) & 0xFF))
            indexBuf.add(UInt8((bo.len >> 16) & 0xFF))
            indexBuf.add(UInt8((bo.len >> 24) & 0xFF))
        }
        
        let bloomFilterData = buildBloomFilter()
        let bloomFilterLen = UInt32(bloomFilterData.size)
        indexBuf.add(UInt8(bloomFilterLen & 0xFF))
        indexBuf.add(UInt8((bloomFilterLen >> 8) & 0xFF))
        indexBuf.add(UInt8((bloomFilterLen >> 16) & 0xFF))
        indexBuf.add(UInt8((bloomFilterLen >> 24) & 0xFF))
        for (b in bloomFilterData) {
            indexBuf.add(b)
        }
        
        indexBuf.add(UInt8(maxVersion & 0xFF))
        indexBuf.add(UInt8((maxVersion >> 8) & 0xFF))
        indexBuf.add(UInt8((maxVersion >> 16) & 0xFF))
        indexBuf.add(UInt8((maxVersion >> 24) & 0xFF))
        indexBuf.add(UInt8((maxVersion >> 32) & 0xFF))
        indexBuf.add(UInt8((maxVersion >> 40) & 0xFF))
        indexBuf.add(UInt8((maxVersion >> 48) & 0xFF))
        indexBuf.add(UInt8((maxVersion >> 56) & 0xFF))
        
        indexBuf.add(UInt8(keyCount & 0xFF))
        indexBuf.add(UInt8((keyCount >> 8) & 0xFF))
        indexBuf.add(UInt8((keyCount >> 16) & 0xFF))
        indexBuf.add(UInt8((keyCount >> 24) & 0xFF))
        
        indexBuf.add(UInt8(uncompressedSize & 0xFF))
        indexBuf.add(UInt8((uncompressedSize >> 8) & 0xFF))
        indexBuf.add(UInt8((uncompressedSize >> 16) & 0xFF))
        indexBuf.add(UInt8((uncompressedSize >> 24) & 0xFF))
        
        let onDiskSize = UInt32(buf.size)
        indexBuf.add(UInt8(onDiskSize & 0xFF))
        indexBuf.add(UInt8((onDiskSize >> 8) & 0xFF))
        indexBuf.add(UInt8((onDiskSize >> 16) & 0xFF))
        indexBuf.add(UInt8((onDiskSize >> 24) & 0xFF))
        
        let staleDataSize: UInt32 = 0
        indexBuf.add(UInt8(staleDataSize & 0xFF))
        indexBuf.add(UInt8((staleDataSize >> 8) & 0xFF))
        indexBuf.add(UInt8((staleDataSize >> 16) & 0xFF))
        indexBuf.add(UInt8((staleDataSize >> 24) & 0xFF))
        
        return indexBuf.toArray()
    }
    
    public func size(): Int64 {
        return buf.size + currentBlock.size()
    }
    
    public func getKeyCount(): UInt32 {
        return keyCount
    }
    
    public func getMaxVersion(): UInt64 {
        return maxVersion
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
    
    private func buildBloomFilter(): Array<Byte> {
        if (bloomFalsePositive <= 0.0 || keyHashes.size == 0) {
            return []
        }
        
        let bitsPerKey = BloomFilter.calcBitsPerKey(bloomFalsePositive)
        let bf = BloomFilter(numKeys: Int64(keyHashes.size), bitsPerKey: bitsPerKey)
        
        for (h in keyHashes) {
            bf.addHash(h)
        }
        
        bf.finish()
        return bf.data()
    }
    
    public func isEmpty(): Bool {
        return keyCount == 0
    }
}

/**
 * BlockOffset - Block 在文件中的位置信息
 */
public struct BlockOffset {
    public let key: Array<Byte>
    public let offset: UInt32
    public let len: UInt32
    
    public init(key: Array<Byte>, offset: UInt32, len: UInt32) {
        this.key = key
        this.offset = offset
        this.len = len
    }
}