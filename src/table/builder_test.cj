package badgercj.table

import std.unittest.*
import std.unittest.testmacro.*

@Test
class TableBuilderTest {
    @TestCase
    func testEmptyTable() {
        let builder = TableBuilder(blockSize: 1024)
        @Assert(builder.isEmpty(), true)
        @Assert(builder.getKeyCount(), 0)
    }
    
    @TestCase
    func testSingleEntry() {
        let builder = TableBuilder(blockSize: 1024)
        let key: Array<Byte> = [1u8, 2u8, 3u8]
        let value = ValueStruct([10u8, 20u8, 30u8])
        
        builder.add(key, value)
        
        @Assert(builder.isEmpty(), false)
        @Assert(builder.getKeyCount(), 1)
        @Assert(builder.size() > 0, true)
    }
    
    @TestCase
    func testMultipleEntries() {
        let builder = TableBuilder(blockSize: 4096)
        
        for (i in 0..100) {
            let key = Array<Byte>(10, {j => UInt8((i + j) % 256)})
            let value = ValueStruct(Array<Byte>(20, {j => UInt8(j)}))
            builder.add(key, value)
        }
        
        @Assert(builder.getKeyCount(), 100)
        
        let data = builder.finish()
        @Assert(data.size > 0, true)
    }
    
    @TestCase
    func testMultipleBlocks() {
        let builder = TableBuilder(blockSize: 256)
        
        for (i in 0..50) {
            let key = Array<Byte>(10, repeat: UInt8(i))
            let value = ValueStruct(Array<Byte>(50, repeat: UInt8(i)))
            builder.add(key, value)
        }
        
        @Assert(builder.getKeyCount(), 50)
        
        let data = builder.finish()
        @Assert(data.size > 256, true)
    }
    
    @TestCase
    func testVersionTracking() {
        let builder = TableBuilder(blockSize: 1024)
        
        let value1 = ValueStruct([1u8], version: 100)
        let value2 = ValueStruct([2u8], version: 200)
        let value3 = ValueStruct([3u8], version: 150)
        
        builder.add([1u8], value1)
        builder.add([2u8], value2)
        builder.add([3u8], value3)
        
        @Assert(builder.getMaxVersion(), 200)
    }
    
    @TestCase
    func testOrderedKeys() {
        let builder = TableBuilder(blockSize: 4096)
        
        let keys: Array<Array<Byte>> = [
            [1u8],
            [2u8],
            [3u8],
            [4u8],
            [5u8]
        ]
        
        for (key in keys) {
            builder.add(key, ValueStruct([0u8]))
        }
        
        @Assert(builder.getKeyCount(), 5)
        
        let data = builder.finish()
        @Assert(data.size > 0, true)
    }
    
    @TestCase
    func testLargeKey() {
        let builder = TableBuilder(blockSize: 4096)
        
        let largeKey = Array<Byte>(1000, {i => UInt8(i % 256)})
        let value = ValueStruct([1u8])
        
        builder.add(largeKey, value)
        
        @Assert(builder.getKeyCount(), 1)
        
        let data = builder.finish()
        @Assert(data.size > 1000, true)
    }
    
    @TestCase
    func testDeleteMarker() {
        let builder = TableBuilder(blockSize: 1024)
        
        let deleteValue = ValueStruct([], meta: Meta.bitDelete)
        builder.add([1u8], deleteValue)
        
        @Assert(builder.getKeyCount(), 1)
        
        let data = builder.finish()
        @Assert(data.size > 0, true)
    }
    
    @TestCase
    func testTableIndexIncluded() {
        let builder = TableBuilder(blockSize: 1024)
        
        for (i in 0..10) {
            let key = [UInt8(i)]
            let value = ValueStruct([UInt8(i * 10)])
            builder.add(key, value)
        }
        
        let data = builder.finish()
        
        @Assert(data.size >= 8, true)
        
        let checksumSize = Int64(data[data.size - 4]) |
                           (Int64(data[data.size - 3]) << 8) |
                           (Int64(data[data.size - 2]) << 16) |
                           (Int64(data[data.size - 1]) << 24)
        
        @Assert(checksumSize, 4)
        
        let indexSize = Int64(data[data.size - 12]) |
                        (Int64(data[data.size - 11]) << 8) |
                        (Int64(data[data.size - 10]) << 16) |
                        (Int64(data[data.size - 9]) << 24)
        
        @Assert(indexSize > 0, true)
    }
}