package badgercj.table

import std.collection.*
import badgercj.utils.{compareKeys, u32FromLE, u64FromLE}

/**
 * TableIndex - SSTable 索引（按需解析的紧凑表示，阶段 6.1 lazy index）
 *
 * 编码布局（磁盘/内存一致）：
 *   [smallestLen][smallest][biggestLen][biggest][blockCount]
 *   blockCount × { [keyLen u32][key][offset u32][len u32][compression u8] }
 *   [bloomLen u32][bloom][maxVersion u64][keyCount u32][uncompressedSize u32]
 *   [onDiskSize u32][staleDataSize u32]
 *
 * 内存模型：
 * - 只保留**一份**索引原始字节 `raw` + 每块 4 字节的位置表 `positions`；
 * - 块 key 不再在构造时复制成独立数组：查找时直接在 raw 上逐字节比较
 *   （compareKeyWithBlock），只有真正要交出 key 的调用（BlockIterator 首 key、
 *   区间切分、诊断）才按需复制一份。
 *
 * 对比旧实现（每块一个 BlockOffset 对象 + 一份 key 副本）：多表常驻时省掉
 * 对象头与重复 key 副本；索引本体从「N 个小对象」变成「1 块字节 + 4B/块」。
 */
protected class TableIndex {
    private let raw: Array<Byte>
    private let positions: Array<UInt32>
    private let blockCnt: Int64
    public let bloomFilter: Array<Byte>
    public let maxVersion: UInt64
    public let keyCount: UInt32
    public let uncompressedSize: UInt32
    public let onDiskSize: UInt32
    public let staleDataSize: UInt32
    public let tableSmallest: Array<Byte>
    public let tableBiggest: Array<Byte>

    private init(raw: Array<Byte>, positions: Array<UInt32>, bloomFilter: Array<Byte>,
                 maxVersion: UInt64, keyCount: UInt32, uncompressedSize: UInt32, onDiskSize: UInt32,
                 staleDataSize: UInt32, tableSmallest: Array<Byte>, tableBiggest: Array<Byte>) {
        this.raw = raw
        this.positions = positions
        this.blockCnt = Int64(positions.size)
        this.bloomFilter = bloomFilter
        this.maxVersion = maxVersion
        this.keyCount = keyCount
        this.uncompressedSize = uncompressedSize
        this.onDiskSize = onDiskSize
        this.staleDataSize = staleDataSize
        this.tableSmallest = tableSmallest
        this.tableBiggest = tableBiggest
    }

    public static func empty(): TableIndex {
        TableIndex([], Array<UInt32>(0, repeat: 0), [], 0, 0, 0, 0, 0, [], [])
    }

    /** 索引本体占用的堆字节（诊断/测试用：raw + 位置表）。 */
    public func heapBytes(): Int64 {
        Int64(raw.size) + Int64(positions.size) * 4
    }

    public func blockCount(): Int64 {
        blockCnt
    }

    private func keyStart(pos: Int64): Int64 {
        pos + 4
    }

    private func keyLenAtPos(pos: Int64): Int64 {
        Int64(u32FromLE(raw, pos))
    }

    private func keyPos(i: Int64): Int64 {
        Int64(positions[i])
    }

    /** 第 i 块首 key（按需复制；热路径请用 compareKeyWithBlock）。 */
    public func keyAt(i: Int64): Array<Byte> {
        let pos = keyPos(i)
        let len = keyLenAtPos(pos)
        let start = keyStart(pos)
        raw[start..(start + len)]
    }

    public func offsetAt(i: Int64): UInt32 {
        let pos = keyPos(i)
        let afterKey = keyStart(pos) + keyLenAtPos(pos)
        u32FromLE(raw, afterKey)
    }

    public func lenAt(i: Int64): UInt32 {
        let pos = keyPos(i)
        let afterKey = keyStart(pos) + keyLenAtPos(pos)
        u32FromLE(raw, afterKey + 4)
    }

    public func compressionAt(i: Int64): CompressionType {
        let pos = keyPos(i)
        let afterKey = keyStart(pos) + keyLenAtPos(pos)
        if (raw[afterKey + 8] == 1) {
            CompressionType.Snappy
        } else {
            CompressionType.None
        }
    }

    /**
     * 比较 `key` 与第 i 块首 key（等价 `compareKeys(key, keyAt(i))`，但不复制块 key）。
     * 逐字节字典序：短者小；相等返回 0。
     */
    public func compareKeyWithBlock(i: Int64, key: Array<Byte>): Int64 {
        if (i < 0 || i >= blockCnt) {
            return 1
        }
        let pos = keyPos(i)
        let blockKeyLen = keyLenAtPos(pos)
        let start = keyStart(pos)
        var j: Int64 = 0
        while (j < Int64(key.size) && j < blockKeyLen) {
            let a = key[j]
            let b = raw[start + j]
            if (a < b) {
                return -1
            }
            if (a > b) {
                return 1
            }
            j++
        }
        let aLen = Int64(key.size)
        if (aLen < blockKeyLen) {
            return -1
        }
        if (aLen > blockKeyLen) {
            return 1
        }
        0
    }

    /** 二分查找：返回最后一个「块首 key <= key」的块号（原 findBlock 的定位核心）。 */
    public func findBlockPos(key: Array<Byte>): Int64 {
        if (blockCnt == 0) {
            return -1
        }
        var left: Int64 = 0
        var right: Int64 = blockCnt - 1
        while (left < right) {
            let mid = (left + right) / 2
            if (compareKeyWithBlock(mid, key) > 0) {
                left = mid + 1
            } else {
                right = mid
            }
        }
        left
    }

    public func seekBlock(key: Array<Byte>): Option<UInt32> {
        let idx = findBlockPos(key)
        if (idx >= blockCnt || idx < 0) {
            return None
        }
        Some(UInt32(idx))
    }

    /**
     * 从字节数组解析 TableIndex
     */
    public static func decodeFromData(data: Array<Byte>): TableIndex {
        let size = Int64(data.size)
        if (size < 12) {
            return empty()
        }

        let checksumSize = u32FromLE(data, size - 4)
        let checksumStart = size - 4 - Int64(checksumSize)
        if (checksumStart < 4) {
            return empty()
        }

        let indexSize = u32FromLE(data, checksumStart - 4)
        let indexEnd = checksumStart - 4
        let indexStart = indexEnd - Int64(indexSize)
        if (indexStart < 0 || indexEnd > size) {
            return empty()
        }
        decode(data[indexStart..indexEnd])
    }

    /**
     * 从 TableData 按需解析索引：只读文件尾部三段（crc 长度、indexSize、index 本体），
     * 不把整张表读进内存。
     */
    public static func decodeFromTableData(td: TableData): TableIndex {
        let size = td.size()
        if (size < 12) {
            return empty()
        }
        let tail = td.read(size - 4, 4)
        let checksumSize = u32FromLE(tail, 0)
        let checksumStart = size - 4 - Int64(checksumSize)
        if (checksumStart < 4) {
            return empty()
        }
        let lenBytes = td.read(checksumStart - 4, 4)
        let indexSize = u32FromLE(lenBytes, 0)
        let indexEnd = checksumStart - 4
        let indexStart = indexEnd - Int64(indexSize)
        if (indexStart < 0 || indexEnd > size) {
            return empty()
        }
        decode(td.read(indexStart, Int64(indexSize)))
    }

    /**
     * 从索引字节解析：块条目只记录位置（4B/块），key 不复制；元数据在后面一次读出。
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

        let positions = Array<UInt32>(Int64(blockCount), repeat: 0)
        for (i in 0..Int64(blockCount)) {
            positions[i] = UInt32(offset)
            let keyLen = u32FromLE(data, offset)
            offset += 4 + Int64(keyLen)
            offset += 4  // blockOffset
            offset += 4  // blockLen
            offset += 1  // compression
        }

        let bloomLen = u32FromLE(data, offset)
        offset += 4
        let bloomFilter = data[offset..(offset + Int64(bloomLen))]
        offset += Int64(bloomLen)

        let maxVersion = u64FromLE(data, offset)
        offset += 8
        let keyCount = u32FromLE(data, offset)
        offset += 4
        let uncompressedSize = u32FromLE(data, offset)
        offset += 4
        let onDiskSize = u32FromLE(data, offset)
        offset += 4
        let staleDataSize = u32FromLE(data, offset)

        TableIndex(data, positions, bloomFilter, maxVersion, keyCount, uncompressedSize, onDiskSize,
            staleDataSize, tableSmallest, tableBiggest)
    }
}
