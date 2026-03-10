package badgercj.skiplist

import std.unittest.*
import std.unittest.testmacro.*
import badgercj.arena.*
import std.sync.*

@Test
class SkiplistTest {
    private let arena: Arena
    private let atomicStorage: AtomicStorage
    private let list: Skiplist
    
    public init() {
        this.arena = Arena(4096)
        this.atomicStorage = AtomicStorage(1024)
        this.list = Skiplist(arena, atomicStorage)
    }
    
    @BeforeAll
    func setup() {
    }
    
    @AfterAll
    func cleanup() {
    }
    
    @TestCase
    func testNew() {
        @Assert(list.getHeight(), 1)
    }
    
    @TestCase
    func testPutGet() {
        let key: Array<Byte> = [1u8, 2u8, 3u8]
        list.add(key, 100u64)
        
        let node = list.get(key)
        if (node.isSome()) {
            if (let Some(n) <- node) {
                @Assert(n.getValue(), 100u64)
            }
        } else {
            @Fail("Key not found")
        }
    }
    
    @TestCase
    func testUpdate() {
        let key: Array<Byte> = [1u8, 2u8, 3u8]
        list.add(key, 100u64)
        list.add(key, 200u64)
        
        let node = list.get(key)
        if (node.isSome()) {
            if (let Some(n) <- node) {
                @Assert(n.getValue(), 200u64)
            }
        } else {
            @Fail("Key not found")
        }
    }
    
    @TestCase
    func testMultipleKeys() {
        list.add([1u8], 10u64)
        list.add([2u8], 20u64)
        list.add([1u8, 2u8], 30u64)
        list.add([1u8, 2u8, 3u8], 40u64)
        list.add([2u8, 3u8], 50u64)
        
        let n1 = list.get([1u8])
        if (n1.isSome()) {
            if (let Some(n) <- n1) {
                @Assert(n.getValue(), 10u64)
            }
        }
        
        let n2 = list.get([2u8])
        if (n2.isSome()) {
            if (let Some(n) <- n2) {
                @Assert(n.getValue(), 20u64)
            }
        }
        
        let n3 = list.get([1u8, 2u8])
        if (n3.isSome()) {
            if (let Some(n) <- n3) {
                @Assert(n.getValue(), 30u64)
            }
        }
    }
    
    @TestCase
    func testNotFound() {
        list.add([1u8, 2u8, 3u8], 100u64)
        let node = list.get([4u8, 5u8, 6u8])
        @Assert(node.isNone(), true)
    }
    
    @TestCase
    func testEmptyKey() {
        let key: Array<Byte> = []
        list.add(key, 123u64)
        
        let node = list.get(key)
        if (node.isSome()) {
            if (let Some(n) <- node) {
                @Assert(n.getValue(), 123u64)
            }
        } else {
            @Fail("Empty key not found")
        }
    }
    
    @TestCase
    func testManyInsertions() {
        let testArena = Arena(1024 * 1024)
        let testAtomicStorage = AtomicStorage(4096)
        let testList = Skiplist(testArena, testAtomicStorage)
        
        let count = 100
        for (i in 0..count) {
            let key = [UInt8(i % 256), UInt8((i / 256) % 256)]
            testList.add(key, UInt64(i * 10))
        }
        
        for (i in 0..count) {
            let key = [UInt8(i % 256), UInt8((i / 256) % 256)]
            let node = testList.get(key)
            if (node.isSome()) {
                if (let Some(n) <- node) {
                    @Assert(n.getValue(), UInt64(i * 10))
                }
            } else {
                @Fail("Key ${i} not found")
            }
        }
    }
}
