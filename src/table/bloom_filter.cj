package badgercj.table

/**
 * BloomFilter - 布隆过滤器
 * 
 * 快速判断 key 是否可能存在
 * 
 * 参考：github.com/dgraph-io/badger/v4/util/bloom.go
 */
public class BloomFilter {
    private let bits: Array<Byte>
    private let numBits: Int64
    private let numHashes: Int64
    
    public init(numBits: Int64) {
        this.numBits = numBits
        this.numHashes = 7
        let numBytes = (numBits + 7) / 8
        this.bits = Array<Byte>(numBytes, repeat: 0)
    }
    
    public init(data: Array<Byte>) {
        this.bits = data
        this.numBits = Int64(bits.size) * 8
        this.numHashes = 7
    }
    
    public func add(key: Array<Byte>): Unit {
        let (h1, h2) = hashKey(key)
        
        for (i in 0..numHashes) {
            let bit = (h1 + UInt64(i) * h2) % UInt64(numBits)
            setBit(bit)
        }
    }
    
    public func mayContain(key: Array<Byte>): Bool {
        let (h1, h2) = hashKey(key)
        
        for (i in 0..numHashes) {
            let bit = (h1 + UInt64(i) * h2) % UInt64(numBits)
            if (!testBit(bit)) {
                return false
            }
        }
        
        return true
    }
    
    private func hashKey(key: Array<Byte>): (UInt64, UInt64) {
        var h1: UInt64 = 0
        var h2: UInt64 = 0
        
        for (b in key) {
            h1 = h1 * 31 + UInt64(b)
            h2 = h2 * 37 + UInt64(b)
        }
        
        return (h1, h2)
    }
    
    private func setBit(bit: UInt64): Unit {
        let byteIdx = Int64(bit / 8)
        let bitIdx = Int64(bit % 8)
        
        if (byteIdx < bits.size) {
            bits[byteIdx] |= (1 << bitIdx)
        }
    }
    
    private func testBit(bit: UInt64): Bool {
        let byteIdx = Int64(bit / 8)
        let bitIdx = Int64(bit % 8)
        
        if (byteIdx >= bits.size) {
            return false
        }
        
        return (bits[byteIdx] & (1 << bitIdx)) != 0
    }
    
    public func data(): Array<Byte> {
        return bits
    }
    
    public func size(): Int64 {
        return numBits
    }
}