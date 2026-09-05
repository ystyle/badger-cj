package badgercj.table

import std.collection.*
import std.math.*

/**
 * BloomFilter - 布隆过滤器
 * 
 * 快速判断 key 是否可能存在，减少磁盘访问
 * 
 * 格式（兼容 Go BadgerDB）：
 * - 前 n 字节：位数组
 * - 最后 1 字节：k（哈希函数数量）
 * 
 * 参考：github.com/dgraph-io/badger/v4/util/bloom.go
 */
protected class BloomFilter {
    private var bits: ArrayList<Byte>
    private var numBits: Int64
    private var numHashes: Int64
    
    public init(bitsPerKey!: Int64 = 10) {
        this.numHashes = BloomFilter.calcNumHashes(bitsPerKey)
        this.numBits = 64
        this.bits = zeroBits(8)
    }
    
    public init(numKeys!: Int64, bitsPerKey!: Int64 = 10) {
        this.numHashes = BloomFilter.calcNumHashes(bitsPerKey)
        
        var nBits = numKeys * bitsPerKey
        if (nBits < 64) {
            nBits = 64
        }
        let nBytes = (nBits + 7) / 8
        this.numBits = nBytes * 8
        this.bits = zeroBits(nBytes)
    }
    
    // 全 0 bits 构造：规避闭包构造（cjc 缺陷见
    // docs/issue/2026-09-05-array-closure-ctor-last-byte-flip.md）
    private static func zeroBits(n: Int64): ArrayList<Byte> {
        let list = ArrayList<Byte>()
        var i: Int64 = 0
        while (i < n) {
            list.add(0)
            i++
        }
        list
    }

    public init(data: Array<Byte>) {
        this.bits = ArrayList<Byte>()
        for (b in data) {
            bits.add(b)
        }
        
        if (bits.size < 2) {
            this.numBits = 0
            this.numHashes = 0
            return
        }
        
        let k = bits[bits.size - 1]
        this.numHashes = Int64(k)
        this.numBits = Int64(bits.size - 1) * 8
    }
    
    public static func calcNumHashes(bitsPerKey: Int64): Int64 {
        var k = Int64(Float64(bitsPerKey) * 0.69)
        if (k < 1) { k = 1 }
        if (k > 30) { k = 30 }
        return k
    }
    
    public static func calcBitsPerKey(fp: Float64): Int64 {
        let size = -1.0 * Float64(log(fp)) / (0.69314718056 * 0.69314718056)
        let locs = ceil(0.69314718056 * size)
        return Int64(locs)
    }
    
    public func add(key: Array<Byte>): Unit {
        addHash(hash(key))
    }
    
    @OverflowWrapping
    public func addHash(h: UInt32): Unit {
        if (numBits == 0) { return }
        
        let delta = (h >> 17) | (h << 15)
        var hh = h
        
        for (j in 0..numHashes) {
            let bitPos = UInt64(hh) % UInt64(numBits)
            setBit(bitPos)
            hh = hh + delta
        }
    }
    
    public func mayContain(key: Array<Byte>): Bool {
        mayContainHash(hash(key))
    }
    
    @OverflowWrapping
    public func mayContainHash(h: UInt32): Bool {
        if (bits.size < 2) { return false }
        
        let k = bits[bits.size - 1]
        if (k > 30) { return true }
        
        let nBits = UInt32(bits.size - 1) * 8
        let delta = (h >> 17) | (h << 15)
        var hh = h
        
        for (j in 0..Int64(k)) {
            let bitPos = hh % nBits
            let byteIdx = bitPos / 8
            let bitIdx = bitPos % 8
            
            if (Int64(byteIdx) >= bits.size - 1) {
                return false
            }
            
            if ((bits[Int64(byteIdx)] & UInt8(1 << bitIdx)) == 0) {
                return false
            }
            hh = hh + delta
        }
        
        return true
    }
    
    @OverflowWrapping
    public static func hash(data: Array<Byte>): UInt32 {
        const seed: UInt32 = 0xbc9f1d34
        const m: UInt32 = 0xc6a4a793
        
        var h: UInt32 = seed ^ (UInt32(data.size) * m)
        var i: Int64 = 0
        
        while (i + 4 <= data.size) {
            let b0 = UInt32(data[i])
            let b1 = UInt32(data[i + 1]) << 8
            let b2 = UInt32(data[i + 2]) << 16
            let b3 = UInt32(data[i + 3]) << 24
            h = h + (b0 | b1 | b2 | b3)
            h = h * m
            h = h ^ (h >> 16)
            i += 4
        }
        
        let remaining = data.size - i
        if (remaining >= 3) {
            h = h + (UInt32(data[i + 2]) << 16)
        }
        if (remaining >= 2) {
            h = h + (UInt32(data[i + 1]) << 8)
        }
        if (remaining >= 1) {
            h = h + UInt32(data[i])
            h = h * m
            h = h ^ (h >> 24)
        }
        
        return h
    }
    
    private func setBit(bitPos: UInt64): Unit {
        let byteIdx = Int64(bitPos / 8)
        let bitIdx = Int64(bitPos % 8)
        
        if (byteIdx < bits.size) {
            bits[byteIdx] = bits[byteIdx] | UInt8(1 << bitIdx)
        }
    }
    
    public func finish(): Unit {
        bits.add(UInt8(numHashes))
    }
    
    public func data(): Array<Byte> {
        bits.toArray()
    }
    
    public func size(): Int64 {
        Int64(bits.size)
    }
}