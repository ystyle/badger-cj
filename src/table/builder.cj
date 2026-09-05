package badgercj.table

import std.collection.*
import badgercj.encoding.*
import ystyle::crc.*
import badgercj.utils.compareKeys
import snappy.encode
import snappy.maxEncodedLen

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
protected class TableBuilder {
    private let blockSize: Int64
    private let bloomFalsePositive: Float64
    private let compression: CompressionType
    private var currentBlock: BlockBuilder
    // L1（单拷贝）：各 block 压缩完成后整块持有（零逐字节累积），finish() 一次拼接
    // 为唯一一份连续数据——不再有 ArrayList<Byte> 全表累积 + toArray 第二份拷贝
    private var blocks: ArrayList<Array<Byte>>
    // 已落 blocks 的累计字节数（文件 on-disk 偏移/大小基准）
    private var writtenSize: Int64
    private var blockOffsets: ArrayList<BlockOffset>
    private var keyHashes: ArrayList<UInt32>
    private var keyCount: UInt32
    private var maxVersion: UInt64
    private var uncompressedSize: UInt32
    private var compressedSize: UInt32
    private var finished: Bool
    private var tableSmallest: Array<Byte>
    private var tableBiggest: Array<Byte>
    
    public init(blockSize!: Int64 = 4 * 1024, bloomFalsePositive!: Float64 = 0.01, compression!: CompressionType = CompressionType.None) {
        this.blockSize = blockSize
        this.bloomFalsePositive = bloomFalsePositive
        this.compression = compression
        this.currentBlock = BlockBuilder(blockSize: blockSize)
        this.blocks = ArrayList<Array<Byte>>()
        this.writtenSize = 0
        this.blockOffsets = ArrayList<BlockOffset>()
        this.keyHashes = ArrayList<UInt32>()
        this.keyCount = 0
        this.maxVersion = 0
        this.uncompressedSize = 0
        this.compressedSize = 0
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
        let offset = UInt32(writtenSize)
        
        // 压缩 Block
        let (finalData, compressionType) = compressBlock(blockData)
        
        let blockOffset = BlockOffset(currentBlock.getBaseKey(), offset, UInt32(finalData.size), compression: compressionType)
        blockOffsets.add(blockOffset)
        
        // L1：整块引用持有，零逐字节累积/扩容搬运
        blocks.add(finalData)
        writtenSize += Int64(finalData.size)
        
        compressedSize += UInt32(finalData.size)
        currentBlock.reset()
    }
    
    /**
     * 压缩 Block 数据
     */
    private func compressBlock(data: Array<Byte>): (Array<Byte>, CompressionType) {
        if (compression == CompressionType.None) {
            return (data, CompressionType.None)
        }
        
        let maxLen = maxEncodedLen(data.size)
        if (maxLen < 0) {
            return (data, CompressionType.None)
        }
        
        let dst = Array<Byte>(maxLen, repeat: 0)
        let compressed = encode(dst, data)
        
        // 如果压缩后更大或没明显压缩，使用原始数据
        if (compressed.size >= data.size) {
            return (data, CompressionType.None)
        }
        
        return (compressed, CompressionType.Snappy)
    }
    
    /**
     * 完成 SSTable 构建并返回字节数组
     * 
     * L1：一次分配最终缓冲，各 block/index 整块拷入并同步增量喂 CRC32C——
     * 全表仅存在一份连续数据（供落盘 + 磁盘 Table 常驻引用），构建期不再有
     * 「ArrayList 累积 + toArray 副本」的双份驻留。
     * 
     * 布局（与旧实现位级一致）：[Block 1..N][Index][Index Size 4B][CRC 4B][CRC Size 4B]
     */
    public func finish(): Array<Byte> {
        if (finished) {
            throw Exception("TableBuilder already finished")
        }
        
        finished = true
        finishBlock()
        
        if (keyCount == 0) {
            // 空表无数据可落盘：返回空数组，调用方（flushToLevel 等）据此跳过
            // 建表/落盘（行为修正：旧实现空表也会产出 index 头 → 落盘空 .sst）
            return []
        }
        
        let indexData = buildTableIndex()
        let indexSize = UInt32(indexData.size)
        
        // 尾部 8B 追加：[crc 4B][crcSize 4B=4]，crc 覆盖 blocks+index+indexSize
        let bodyLen = writtenSize + Int64(indexData.size) + 4
        let out = Array<Byte>(bodyLen + 8, repeat: 0)
        let crc = CRC32C()
        var off: Int64 = 0
        
        // 1) 全部 block
        for (blk in blocks) {
            copyInto(out, off, blk)
            crc.write(blk)  // 增量喂原始块引用，零额外拷贝
            off += blk.size
        }
        
        // 2) index
        copyInto(out, off, indexData)
        crc.write(indexData)
        off += Int64(indexData.size)
        
        // 3) indexSize 4B
        for (k in 0..4) {
            out[off + k] = UInt8((indexSize >> (k * 8)) & 0xFF)
        }
        let iszBytes = [UInt8(indexSize & 0xFF), UInt8((indexSize >> 8) & 0xFF),
            UInt8((indexSize >> 16) & 0xFF), UInt8((indexSize >> 24) & 0xFF)]
        crc.write(iszBytes)
        off += 4
        
        // 4) checksum
        let checksum = crc.sum32()
        for (k in 0..4) {
            out[off + k] = UInt8((checksum >> (k * 8)) & 0xFF)
        }
        off += 4
        
        // 5) checksum size（固定 4 字节）
        out[off] = 4
        out[off + 1] = 0
        out[off + 2] = 0
        out[off + 3] = 0
        
        return out
    }
    
    // 逐字节块拷贝 helper（块级整体搬入最终缓冲）
    private func copyInto(dst: Array<Byte>, dstOff: Int64, src: Array<Byte>): Unit {
        var k: Int64 = 0
        while (k < src.size) {
            dst[dstOff + k] = src[k]
            k++
        }
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
            
            indexBuf.add(UInt8(CompressionTypeValue(bo.compression)))
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
        
        let onDiskSize = UInt32(writtenSize)
        indexBuf.add(UInt8(onDiskSize & 0xFF))
        indexBuf.add(UInt8((onDiskSize >> 8) & 0xFF))
        indexBuf.add(UInt8((onDiskSize >> 16) & 0xFF))
        indexBuf.add(UInt8((onDiskSize >> 24) & 0xFF))
        
        indexBuf.add(UInt8(compressedSize & 0xFF))
        indexBuf.add(UInt8((compressedSize >> 8) & 0xFF))
        indexBuf.add(UInt8((compressedSize >> 16) & 0xFF))
        indexBuf.add(UInt8((compressedSize >> 24) & 0xFF))
        
        let staleDataSize: UInt32 = 0
        indexBuf.add(UInt8(staleDataSize & 0xFF))
        indexBuf.add(UInt8((staleDataSize >> 8) & 0xFF))
        indexBuf.add(UInt8((staleDataSize >> 16) & 0xFF))
        indexBuf.add(UInt8((staleDataSize >> 24) & 0xFF))
        
        return indexBuf.toArray()
    }
    
    public func size(): Int64 {
        return writtenSize + currentBlock.size()
    }
    
    public func getKeyCount(): UInt32 {
        return keyCount
    }
    
    public func getMaxVersion(): UInt64 {
        return maxVersion
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
    public let compression: CompressionType
    
    public init(key: Array<Byte>, offset: UInt32, len: UInt32, compression!: CompressionType = CompressionType.None) {
        this.key = key
        this.offset = offset
        this.len = len
        this.compression = compression
    }
}