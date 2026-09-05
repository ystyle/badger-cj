package badgercj.table

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*

@Test
class TableIntegrationTest {
    
    @TestCase
    func testBuildAndReadSingleEntry() {
        let builder = TableBuilder(blockSize: 1024)
        let key: Array<Byte> = [1u8, 2u8, 3u8]
        let value = ValueStruct([10u8, 20u8, 30u8])
        
        builder.add(key, value)
        let data = builder.finish()
        
        @Assert(data.size > 0, true)
        
        let table = Table(1, data)
        
        let result = table.get(key)
        @Assert(result.isSome(), true)
        
        let val = result.getOrThrow()
        @Assert(val.size, 3)
        @Assert(val[0], 10u8)
        @Assert(val[1], 20u8)
        @Assert(val[2], 30u8)
    }
    
    @TestCase
    func testBuildAndReadMultipleEntries() {
        let builder = TableBuilder(blockSize: 4096)
        let entries: ArrayList<(Array<Byte>, Array<Byte>)> = ArrayList<(Array<Byte>, Array<Byte>)>()
        
        for (i in 0..100) {
            let key = Array<Byte>(8, {j => UInt8(i)})
            let val = Array<Byte>(16, {j => UInt8((i + j) % 256)})
            entries.add((key, val))
            builder.add(key, ValueStruct(val))
        }
        
        let data = builder.finish()
        let table = Table(1, data)
        
        @Assert(table.keyCount, 100)
        
        for ((key, expectedVal) in entries) {
            let result = table.get(key)
            @Assert(result.isSome(), true)
            let val = result.getOrThrow()
            @Assert(val.size, expectedVal.size)
            for (j in 0..val.size) {
                @Assert(val[j], expectedVal[j])
            }
        }
    }
    
    @TestCase
    func testBuildAndReadMultipleBlocks() {
        let builder = TableBuilder(blockSize: 256)
        
        for (i in 0..50) {
            let key = Array<Byte>(8, repeat: UInt8(i))
            let value = ValueStruct(Array<Byte>(50, repeat: UInt8(i)))
            builder.add(key, value)
        }
        
        let data = builder.finish()
        let table = Table(1, data)
        
        @Assert(table.numBlocks() > 1, true)
        
        for (i in 0..50) {
            let key = Array<Byte>(8, repeat: UInt8(i))
            let result = table.get(key)
            @Assert(result.isSome(), true)
            
            let val = result.getOrThrow()
            @Assert(val.size, 50)
            for (j in 0..val.size) {
                @Assert(val[j], UInt8(i))
            }
        }
    }
    
    @TestCase
    func testIteratorForward() {
        let builder = TableBuilder(blockSize: 1024)
        let keys: ArrayList<Array<Byte>> = ArrayList<Array<Byte>>()
        
        for (i in 0..20) {
            let key = Array<Byte>(4, {j => UInt8((i * 4 + j) % 256)})
            keys.add(key)
            builder.add(key, ValueStruct([UInt8(i)]))
        }
        
        let data = builder.finish()
        let table = Table(1, data)
        let iter = table.newIterator()
        
        var count: Int64 = 0
        iter.seekFirst()
        while (iter.isValid()) {
            count++
            iter.next()
        }
        
        @Assert(count, 20)
    }
    
    @TestCase
    func testIteratorSeek() {
        let builder = TableBuilder(blockSize: 1024)
        
        for (i in 0..100) {
            let key = Array<Byte>(4, {j => UInt8((i * 4 + j) % 256)})
            builder.add(key, ValueStruct([UInt8(i)]))
        }
        
        let data = builder.finish()
        let table = Table(1, data)
        let iter = table.newIterator()
        
        let seekKey = Array<Byte>(4, {j => UInt8((50 * 4 + j) % 256)})
        iter.seek(seekKey)
        
        @Assert(iter.isValid(), true)
        
        let key = iter.key()
        @Assert(key.size, 4)
    }
    
    @TestCase
    func testNonExistentKey() {
        let builder = TableBuilder(blockSize: 1024)
        
        for (i in 0..10) {
            let key = Array<Byte>(4, {j => UInt8((i * 4 + j) % 256)})
            builder.add(key, ValueStruct([UInt8(i)]))
        }
        
        let data = builder.finish()
        let table = Table(1, data)
        
        let nonExistentKey = Array<Byte>(4, {j => UInt8(255 - j)})
        let result = table.get(nonExistentKey)
        
        @Assert(result.isSome(), false)
    }
    
    @TestCase
    func testVersionTracking() {
        let builder = TableBuilder(blockSize: 1024)
        
        builder.add([1u8], ValueStruct([1u8], version: 100))
        builder.add([2u8], ValueStruct([2u8], version: 200))
        builder.add([3u8], ValueStruct([3u8], version: 150))
        
        @Assert(builder.getMaxVersion(), 200)
        
        let data = builder.finish()
        @Assert(data.size > 0, true)
        
        let table = Table(1, data)
        
        @Assert(table.get([1u8]).isSome(), true)
        @Assert(table.get([2u8]).isSome(), true)
        @Assert(table.get([3u8]).isSome(), true)
    }
    
    @TestCase
    func testDeleteMarker() {
        let builder = TableBuilder(blockSize: 1024)
        
        let deleteValue = ValueStruct([], meta: Meta.bitDelete)
        builder.add([1u8], deleteValue)
        
        let data = builder.finish()
        let table = Table(1, data)
        
        let result = table.get([1u8])
        @Assert(result.isSome(), true)
        
        let val = result.getOrThrow()
        @Assert(val.size, 0)
    }
    
    @TestCase
    func testSmallestBiggest() {
        let builder = TableBuilder(blockSize: 1024)
        
        let keys: Array<Array<Byte>> = [
            [1u8, 0u8, 0u8, 0u8],
            [2u8, 0u8, 0u8, 0u8],
            [3u8, 0u8, 0u8, 0u8],
            [5u8, 0u8, 0u8, 0u8],
            [9u8, 0u8, 0u8, 0u8]
        ]
        
        for (key in keys) {
            builder.add(key, ValueStruct([0u8]))
        }
        
        let data = builder.finish()
        let table = Table(1, data)
        
        @Assert(table.smallest.size > 0, true)
        @Assert(table.biggest.size > 0, true)
        @Assert(table.keyCount, 5)
    }
    
    @TestCase
    func testEmptyTable() {
        let builder = TableBuilder(blockSize: 1024)
        let data = builder.finish()
        
        // L1 行为修正（builder_l1_test 同步）：空表无数据 → finish 返回空数组，
        // 调用方据此跳过建表/落盘（旧实现对空表产出 index 头 → 落盘空 .sst）
        @Assert(data.size, 0)
        
        let table = Table(1, data)
        
        @Assert(table.keyCount, 0)
        @Assert(table.numBlocks(), 0)
        @Assert(table.get([1u8]).isSome(), false)
    }
    
    @TestCase
    func testLargeValues() {
        let builder = TableBuilder(blockSize: 4096)
        
        let largeValue = Array<Byte>(2000, {i => UInt8(i % 256)})
        builder.add([1u8], ValueStruct(largeValue))
        
        let data = builder.finish()
        let table = Table(1, data)
        
        let result = table.get([1u8])
        @Assert(result.isSome(), true)
        
        let val = result.getOrThrow()
        @Assert(val.size, 2000)
        for (i in 0..val.size) {
            @Assert(val[i], UInt8(i % 256))
        }
    }
    
    @TestCase
    func testSequentialKeys() {
        let builder = TableBuilder(blockSize: 1024)
        
        for (i in 0..1000) {
            let hi = UInt8(i / 256)
            let lo = UInt8(i % 256)
            let key = [hi, lo, 0u8, 0u8]
            builder.add(key, ValueStruct([UInt8(i % 256)]))
        }
        
        let data = builder.finish()
        let table = Table(1, data)
        
        @Assert(table.keyCount, 1000)
        
        for (i in 0..1000) {
            let hi = UInt8(i / 256)
            let lo = UInt8(i % 256)
            let key = [hi, lo, 0u8, 0u8]
            let result = table.get(key)
            @Assert(result.isSome(), true)
        }
    }
    
    @TestCase
    func testBlockIterator() {
        let builder = TableBuilder(blockSize: 256)
        
        for (i in 0..50) {
            let key = Array<Byte>(8, repeat: UInt8(i))
            builder.add(key, ValueStruct(Array<Byte>(20, repeat: UInt8(i))))
        }
        
        let data = builder.finish()
        let table = Table(1, data)
        
        let numBlocks = table.numBlocks()
        @Assert(numBlocks > 1, true)
        
for (i in 0..numBlocks) {
            let blockIter = table.blockIterator(i)
            blockIter.seekToFirst()
            @Assert(blockIter.isValid(), true)
        }
    }
}
