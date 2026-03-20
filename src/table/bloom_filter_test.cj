package badgercj.table

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*

@Test
class BloomFilterTest {
    
    @TestCase
    func testBasicAddAndQuery() {
        let bf = BloomFilter(numKeys: 10, bitsPerKey: 10)
        
        let key1: Array<Byte> = [0x01, 0x02, 0x03]
        let key2: Array<Byte> = [0x04, 0x05, 0x06]
        let key3: Array<Byte> = [0x07, 0x08, 0x09]
        
        bf.add(key1)
        bf.add(key2)
        bf.add(key3)
        bf.finish()
        
        @Assert(bf.mayContain(key1), true)
        @Assert(bf.mayContain(key2), true)
        @Assert(bf.mayContain(key3), true)
    }
    
    @TestCase
    func testSerializeDeserialize() {
        let bf1 = BloomFilter(numKeys: 100, bitsPerKey: 10)
        
        for (i in 0..100) {
            let key = Array<Byte>(8, {j => UInt8((i + j) % 256)})
            bf1.add(key)
        }
        bf1.finish()
        
        let data = bf1.data()
        let bf2 = BloomFilter(data)
        
        for (i in 0..100) {
            let key = Array<Byte>(8, {j => UInt8((i + j) % 256)})
            @Assert(bf2.mayContain(key), true)
        }
    }
    
    @TestCase
    func testFalsePositiveRate() {
        let numKeys: Int64 = 1000
        let bf = BloomFilter(numKeys: numKeys, bitsPerKey: 10)
        
        let keys = ArrayList<Array<Byte>>()
        for (i in 0..numKeys) {
            let key = Array<Byte>(8, {j => UInt8((i * 7 + j) % 256)})
            keys.add(key)
            bf.add(key)
        }
        bf.finish()
        
        var falsePositives: Int64 = 0
        let numTests: Int64 = 10000
        
        for (i in 0..numTests) {
            let testKey = Array<Byte>(8, {j => UInt8(((i + numKeys) * 13 + j) % 256)})
            if (bf.mayContain(testKey)) {
                var found = false
                for (k in keys) {
                    if (k.size == testKey.size) {
                        var isMatch = true
                        for (j in 0..k.size) {
                            if (k[j] != testKey[j]) {
                                isMatch = false
                                break
                            }
                        }
                        if (isMatch) {
                            found = true
                            break
                        }
                    }
                }
                if (!found) {
                    falsePositives++
                }
            }
        }
        
        let actualFP = Float64(falsePositives) / Float64(numTests)
        @Assert(actualFP < 0.05, true)
    }
    
    @TestCase
    func testDisableBloomFilter() {
        let bf = BloomFilter(numKeys: 0, bitsPerKey: 10)
        
        let key: Array<Byte> = [0x01, 0x02, 0x03]
        bf.add(key)
        bf.finish()
        
        @Assert(bf.mayContain(key), true)
    }
    
    @TestCase
    func testHashFunction() {
        let key1: Array<Byte> = [0x01, 0x02, 0x03]
        let key2: Array<Byte> = [0x01, 0x02, 0x03]
        let key3: Array<Byte> = [0x03, 0x02, 0x01]
        
        let h1 = BloomFilter.hash(key1)
        let h2 = BloomFilter.hash(key2)
        let h3 = BloomFilter.hash(key3)
        
        @Assert(h1 == h2)
        @Assert(h1 != h3)
    }
    
    @TestCase
    func testCalcBitsPerKey() {
        let bits1 = BloomFilter.calcBitsPerKey(0.01)
        @Assert(bits1 >= 5, true)
        @Assert(bits1 <= 15, true)
        
        let bits2 = BloomFilter.calcBitsPerKey(0.001)
        @Assert(bits2 > bits1, true)
    }
}

@Test
class TableBloomFilterTest {
    
    @TestCase
    func testTableWithBloomFilter() {
        let builder = TableBuilder(blockSize: 1024, bloomFalsePositive: 0.01)
        
        for (i in 0..50) {
            let key = Array<Byte>(8, {j => UInt8((i + j) % 256)})
            let value = ValueStruct(Array<Byte>(20, {j => UInt8(j)}))
            builder.add(key, value)
        }
        
        let data = builder.finish()
        let table = Table(1, data)
        
        @Assert(table.hasBloomFilter())
        @Assert(table.bloomFilterSize() > 0)
        
        for (i in 0..50) {
            let key = Array<Byte>(8, {j => UInt8((i + j) % 256)})
            let result = table.get(key)
            @Assert(result.isSome())
        }
    }
    
    @TestCase
    func testTableWithoutBloomFilter() {
        let builder = TableBuilder(blockSize: 1024, bloomFalsePositive: 0.0)
        
        for (i in 0..10) {
            let key = Array<Byte>(8, {j => UInt8((i + j) % 256)})
            let value = ValueStruct(Array<Byte>(20, {j => UInt8(j)}))
            builder.add(key, value)
        }
        
        let data = builder.finish()
        let table = Table(1, data)
        
        @Assert(table.hasBloomFilter(), false)
        @Assert(table.bloomFilterSize(), 0)
    }
    
    @TestCase
    func testBloomFilterRejectsNonExistentKey() {
        let builder = TableBuilder(blockSize: 1024, bloomFalsePositive: 0.01)
        
        let existingKey: Array<Byte> = [0x01, 0x02, 0x03]
        builder.add(existingKey, ValueStruct([0x10, 0x20]))
        
        let data = builder.finish()
        let table = Table(1, data)
        
        @Assert(table.mayContain(existingKey))
        
        let nonExistingKey: Array<Byte> = [0xFF, 0xFE, 0xFD]
        let result = table.get(nonExistingKey)
        @Assert(result.isNone())
    }
}