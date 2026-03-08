package badgercj.skiplist

import std.unittest.*
import std.unittest.testmacro.*
import badgercj.arena.*

@Test
class SkiplistTest {
    @TestCase
    func testNew() {
        let arena = Arena(4096)
        let list = Skiplist(arena)
        @Assert(list.getHeight(), 1)
    }
    
    @TestCase
    func testPutGet() {
        let arena = Arena(4096)
        let list = Skiplist(arena)
        
        let key: Array<Byte> = [1u8, 2u8, 3u8]
        list.add(key, 100u64)
        
        let node = list.get(key)
        if (let Some(n) <- node) {
            @Assert(n.getValue(), 100u64)
        } else {
            @Fail("Key not found")
        }
    }
    
    @TestCase
    func testUpdate() {
        let arena = Arena(4096)
        let list = Skiplist(arena)
        
        let key: Array<Byte> = [1u8, 2u8, 3u8]
        list.add(key, 100u64)
        list.add(key, 200u64)
        
        let node = list.get(key)
        if (let Some(n) <- node) {
            @Assert(n.getValue(), 200u64)
        } else {
            @Fail("Key not found")
        }
    }
    
    @TestCase
    func testMultipleKeys() {
        let arena = Arena(8192)
        let list = Skiplist(arena)
        
        let keys: Array<Array<Byte>> = [
            [1u8],
            [2u8],
            [1u8, 2u8],
            [1u8, 2u8, 3u8],
            [2u8, 3u8],
        ]
        
        for (i in 0..keys.size) {
            list.add(keys[i], UInt64(i * 10))
        }
        
        for (i in 0..keys.size) {
            let node = list.get(keys[i])
            if (let Some(n) <- node) {
                @Assert(n.getValue(), UInt64(i * 10))
            } else {
                @Fail("Key ${i} not found")
            }
        }
    }
    
    @TestCase
    func testNotFound() {
        let arena = Arena(4096)
        let list = Skiplist(arena)
        
        list.add([1u8, 2u8, 3u8], 100u64)
        
        let node = list.get([4u8, 5u8, 6u8])
        @Assert(node.isNone(), true)
    }
    
    @TestCase
    func testEmptyKey() {
        let arena = Arena(4096)
        let list = Skiplist(arena)
        
        let key: Array<Byte> = []
        list.add(key, 123u64)
        
        let node = list.get(key)
        if (let Some(n) <- node) {
            @Assert(n.getValue(), 123u64)
        } else {
            @Fail("Empty key not found")
        }
    }
    
    @TestCase
    func testLargeKey() {
        let arena = Arena(8192)
        let list = Skiplist(arena)
        
        let key = Array<Byte>(100, {i => UInt8(i % 256)})
        list.add(key, 999u64)
        
        let node = list.get(key)
        if (let Some(n) <- node) {
            @Assert(n.getValue(), 999u64)
        } else {
            @Fail("Large key not found")
        }
    }
    
    @TestCase
    func testManyInsertions() {
        let arena = Arena(1024 * 1024)
        let list = Skiplist(arena)
        
        let count = 100
        for (i in 0..count) {
            let key = [UInt8(i % 256), UInt8((i / 256) % 256)]
            list.add(key, UInt64(i))
        }
        
        for (i in 0..count) {
            let key = [UInt8(i % 256), UInt8((i / 256) % 256)]
            let node = list.get(key)
            if (let Some(n) <- node) {
                @Assert(n.getValue(), UInt64(i))
            } else {
                @Fail("Key ${i} not found after ${count} insertions")
            }
        }
    }
}