package badgercj.arena

import std.unittest.*
import std.unittest.testmacro.*

@Test
class ArenaTest {
    @TestCase
    func testNew() {
        let arena = Arena(1024)
        @Assert(arena.size, 1024)
    }
    
    @TestCase
    func testAllocate() {
        let arena = Arena(1024)
        let offset1 = arena.allocate(10)
        let offset2 = arena.allocate(20)
        let offset3 = arena.allocate(30)
        
        @Assert(offset1, 1u32)
        @Assert(offset2, 11u32)
        @Assert(offset3, 31u32)
    }
    
    @TestCase
    func testPutBytes() {
        let arena = Arena(1024)
        let data: Array<Byte> = [1u8, 2u8, 3u8, 4u8]
        let offset = arena.putBytes(data)
        
        let retrieved = arena.getBytes(offset, UInt32(4))
        @Assert(retrieved.size, 4)
        @Assert(retrieved[0], 1u8)
        @Assert(retrieved[1], 2u8)
        @Assert(retrieved[2], 3u8)
        @Assert(retrieved[3], 4u8)
    }
    
    @TestCase
    func testPutU32() {
        let arena = Arena(1024)
        let offset = arena.allocate(4)
        arena.putU32(0x12345678u32, offset)
        
        let value = arena.getU32(offset)
        @Assert(value, 0x12345678u32)
    }
    
    @TestCase
    func testPutU64() {
        let arena = Arena(1024)
        let offset = arena.allocate(8)
        arena.putU64(0x123456789ABCDEF0u64, offset)
        
        let value = arena.getU64(offset)
        @Assert(value, 0x123456789ABCDEF0u64)
    }
    
    @TestCase
    func testPutU16() {
        let arena = Arena(1024)
        let offset = arena.allocate(2)
        arena.putU16(0x1234u16, offset)
        
        let value = arena.getU16(offset)
        @Assert(value, 0x1234u16)
    }
    
    @TestCase
    func testPutNode() {
        let arena = Arena(1024)
        let height: Int64 = 5
        let nodeOffset = arena.putNode(height)
        
        @Assert(nodeOffset > 0u32, true)
        @Assert((nodeOffset % 8u32), 0u32)
    }
    
    @TestCase
    func testRemainingSize() {
        let arena = Arena(1024)
        let initial = arena.remainingSize()
        
        arena.allocate(100)
        let remaining = arena.remainingSize()
        
        @Assert(remaining, initial - 100u32)
    }
}