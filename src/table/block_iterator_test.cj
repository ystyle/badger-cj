package badgercj.table

import std.unittest.*
import std.unittest.testmacro.*

@Test
class BlockIteratorTest {
    private func createTestBlock(): Array<Byte> {
        let builder = BlockBuilder(blockSize: 4096)
        
        builder.add([1u8], ValueStruct([10u8]))
        builder.add([2u8], ValueStruct([20u8]))
        builder.add([3u8], ValueStruct([30u8]))
        builder.add([4u8], ValueStruct([40u8]))
        builder.add([5u8], ValueStruct([50u8]))
        
        builder.finish()
    }
    
    @TestCase
    func testSeekToFirst() {
        let block = createTestBlock()
        let iter = BlockIterator(block, [])
        
        iter.seekToFirst()
        @Assert(iter.isValid(), true)
        @Assert(iter.key(), [1u8])
        @Assert(iter.value(), [10u8])
    }
    
    @TestCase
    func testSeekToLast() {
        let block = createTestBlock()
        let iter = BlockIterator(block, [])
        
        iter.seekToLast()
        @Assert(iter.isValid(), true)
        @Assert(iter.key(), [5u8])
        @Assert(iter.value(), [50u8])
    }
    
    @TestCase
    func testSeekToLastThenPrev() {
        let block = createTestBlock()
        let iter = BlockIterator(block, [])
        
        iter.seekToLast()
        @Assert(iter.isValid(), true)
        @Assert(iter.key(), [5u8])
        
        iter.prev()
        @Assert(iter.isValid(), true)
        @Assert(iter.key(), [4u8])
        
        iter.prev()
        @Assert(iter.isValid(), true)
        @Assert(iter.key(), [3u8])
    }
    
    @TestCase
    func testPrevFromStart() {
        let block = createTestBlock()
        let iter = BlockIterator(block, [])
        
        iter.seekToFirst()
        @Assert(iter.isValid(), true)
        
        iter.prev()
        @Assert(iter.isValid(), false)
    }
    
    @TestCase
    func testPrevMultipleTimes() {
        let block = createTestBlock()
        let iter = BlockIterator(block, [])
        
        iter.seekToLast()
        @Assert(iter.isValid(), true)
        
        var count: Int64 = 0
        while (iter.isValid()) {
            count++
            iter.prev()
        }
        
        @Assert(count, 5)
    }
    
    @TestCase
    func testPrevAndNextAlternating() {
        let block = createTestBlock()
        let iter = BlockIterator(block, [])
        
        iter.seekToFirst()
        @Assert(iter.key(), [1u8])
        
        iter.next()
        @Assert(iter.key(), [2u8])
        
        iter.prev()
        @Assert(iter.key(), [1u8])
        
        iter.next()
        @Assert(iter.key(), [2u8])
        
        iter.next()
        @Assert(iter.key(), [3u8])
        
        iter.prev()
        @Assert(iter.key(), [2u8])
    }
    
    @TestCase
    func testSeekToLastEmptyBlock() {
        let builder = BlockBuilder(blockSize: 1024)
        let block = builder.finish()
        
        let iter = BlockIterator(block, [])
        iter.seekToLast()
        @Assert(iter.isValid(), false)
    }
    
    @TestCase
    func testPrevEmptyBlock() {
        let builder = BlockBuilder(blockSize: 1024)
        let block = builder.finish()
        
        let iter = BlockIterator(block, [])
        iter.prev()
        @Assert(iter.isValid(), false)
    }
    
    @TestCase
    func testBackwardIteration() {
        let block = createTestBlock()
        let iter = BlockIterator(block, [])
        
        iter.seekToLast()
        
        let expectedKeys: Array<Array<Byte>> = [[5u8], [4u8], [3u8], [2u8], [1u8]]
        let expectedValues: Array<Array<Byte>> = [[50u8], [40u8], [30u8], [20u8], [10u8]]
        
        var i: Int64 = 0
        while (iter.isValid()) {
            @Assert(iter.key(), expectedKeys[i])
            @Assert(iter.value(), expectedValues[i])
            iter.prev()
            i++
        }
        
        @Assert(i, 5)
    }
    
    @TestCase
    func testSeekThenPrev() {
        let block = createTestBlock()
        let iter = BlockIterator(block, [])
        
        iter.seek([3u8])
        @Assert(iter.isValid(), true)
        @Assert(iter.key(), [3u8])
        
        iter.prev()
        @Assert(iter.isValid(), true)
        @Assert(iter.key(), [2u8])
        
        iter.prev()
        @Assert(iter.isValid(), true)
        @Assert(iter.key(), [1u8])
        
        iter.prev()
        @Assert(iter.isValid(), false)
    }
    
    @TestCase
    func testSeekToLastSingleElement() {
        let builder = BlockBuilder(blockSize: 1024)
        builder.add([42u8], ValueStruct([100u8]))
        let block = builder.finish()
        
        let iter = BlockIterator(block, [])
        iter.seekToLast()
        @Assert(iter.isValid(), true)
        @Assert(iter.key(), [42u8])
        @Assert(iter.value(), [100u8])
        
        iter.prev()
        @Assert(iter.isValid(), false)
    }
}