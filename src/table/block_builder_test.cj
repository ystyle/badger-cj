package badgercj.table

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*

@Test
class BlockBuilderTest {
    @TestCase
    func testEmptyBlock() {
        let builder = BlockBuilder(blockSize: 1024)
        @Assert(builder.isEmpty(), true)
        @Assert(builder.size(), 0)
    }
    
    @TestCase
    func testSingleEntry() {
        let builder = BlockBuilder(blockSize: 1024)
        let key: Array<Byte> = [1u8, 2u8, 3u8]
        let value = ValueStruct([10u8, 20u8, 30u8])
        
        let added = builder.add(key, value)
        @Assert(added, true)
        @Assert(builder.isEmpty(), false)
        @Assert(builder.getKeyCount(), 1)
    }
    
    @TestCase
    func testMultipleEntries() {
        let builder = BlockBuilder(blockSize: 4096)
        
        let keys: Array<Array<Byte>> = [
            [1u8],
            [1u8, 2u8],
            [1u8, 2u8, 3u8],
            [1u8, 2u8, 3u8, 4u8],
        ]
        
        for (i in 0..keys.size) {
            let value = ValueStruct([UInt8(i)])
            let added = builder.add(keys[i], value)
            @Assert(added, true)
        }
        
        @Assert(builder.getKeyCount(), 4)
        
        let data = builder.finish()
        @Assert(data.size > 0, true)
    }
    
    @TestCase
    func testPrefixCompression() {
        let builder = BlockBuilder(blockSize: 4096)
        
        let key1 = "apple".toArray()
        let key2 = "application".toArray()
        let key3 = "applet".toArray()
        
        let added1 = builder.add(key1, ValueStruct([1u8]))
        let added2 = builder.add(key2, ValueStruct([2u8]))
        let added3 = builder.add(key3, ValueStruct([3u8]))
        
        @Assert(added1, true)
        @Assert(added2, true)
        @Assert(added3, true)
        
        let data = builder.finish()
        @Assert(data.size > 0, true)
    }
    
    @TestCase
    func testBlockFull() {
        let builder = BlockBuilder(blockSize: 100)
        
        var count: Int64 = 0
        while (true) {
            let c = count
            let key = Array<Byte>(10, {i => UInt8(c)})
            let value = ValueStruct(Array<Byte>(20, {i => UInt8(i)}))
            
            if (!builder.add(key, value)) {
                break
            }
            count++
        }
        
        @Assert(count > 0, true)
        @Assert(count < 100, true)
        
        let data = builder.finish()
        @Assert(data.size > 0, true)
    }
    
    @TestCase
    func testFinishAndReset() {
        let builder = BlockBuilder(blockSize: 1024)
        
        builder.add([1u8], ValueStruct([10u8]))
        builder.add([2u8], ValueStruct([20u8]))
        
        let data1 = builder.finish()
        @Assert(data1.size > 0, true)
        @Assert(builder.getKeyCount(), 2)
        
        builder.reset()
        @Assert(builder.isEmpty(), true)
        @Assert(builder.getKeyCount(), 0)
        
        builder.add([3u8], ValueStruct([30u8]))
        let data2 = builder.finish()
        @Assert(data2.size > 0, true)
    }
    
    @TestCase
    func testChecksumIncluded() {
        let builder = BlockBuilder(blockSize: 1024)
        
        builder.add([1u8, 2u8, 3u8], ValueStruct([10u8, 20u8, 30u8]))
        
        let data = builder.finish()
        
        @Assert(data.size >= 8, true)
        
        let checksumSize = Int64(data[data.size - 4]) |
                           (Int64(data[data.size - 3]) << 8) |
                           (Int64(data[data.size - 2]) << 16) |
                           (Int64(data[data.size - 1]) << 24)
        
        @Assert(checksumSize, 4)
    }
}