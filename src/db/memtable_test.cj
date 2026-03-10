package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.fs.{remove, exists, Path}
import badgercj.table.*

@Test
class MemTableTest {
    @TestCase
    func testMemTablePutAndGet() {
        let opt = DBOptions(dir: "/tmp/badger_test")
        let mt = MemTable(opt, 0, false)
        
        let key: Array<Byte> = [1u8, 2u8, 3u8]
        let value: Array<Byte> = [4u8, 5u8, 6u8]
        let vs = ValueStruct(value)
        
        mt.put(key, vs)
        
        let result = mt.get(key)
        if (let Some(v) <- result) {
            @Assert(v.value, value)
        } else {
            @Fail("Key not found")
        }
    }
    
    @TestCase
    func testMemTableGetNonExistent() {
        let opt = DBOptions(dir: "/tmp/badger_test")
        let mt = MemTable(opt, 0, false)
        
        let key: Array<Byte> = [1u8, 2u8, 3u8]
        
        let result = mt.get(key)
        if (let Some(_) <- result) {
            @Fail("Should not find non-existent key")
        }
    }
    
    @TestCase
    func testMemTableOverwrite() {
        let opt = DBOptions(dir: "/tmp/badger_test")
        let mt = MemTable(opt, 0, false)
        
        let key: Array<Byte> = [1u8, 2u8, 3u8]
        let value1: Array<Byte> = [4u8, 5u8, 6u8]
        let value2: Array<Byte> = [7u8, 8u8, 9u8]
        
        mt.put(key, ValueStruct(value1))
        mt.put(key, ValueStruct(value2))
        
        let result = mt.get(key)
        if (let Some(v) <- result) {
            @Assert(v.value, value2)
        } else {
            @Fail("Key not found")
        }
    }
    
    @TestCase
    func testMemTableSizeTracking() {
        let opt = DBOptions(dir: "/tmp/badger_test")
        let mt = MemTable(opt, 0, false)
        
        @Assert(mt.sizeInBytes(), 0u64)
        
        let key1: Array<Byte> = [1u8]
        let value1: Array<Byte> = [1u8, 2u8, 3u8]
        mt.put(key1, ValueStruct(value1))
        
        let size1 = mt.sizeInBytes()
        @Assert(size1 > 0u64, true)
        
        let key2: Array<Byte> = [2u8]
        let value2: Array<Byte> = [4u8, 5u8, 6u8]
        mt.put(key2, ValueStruct(value2))
        
        let size2 = mt.sizeInBytes()
        @Assert(size2 > size1, true)
    }
    
    @TestCase
    func testMemTableShouldFlush() {
        let opt = DBOptions(dir: "/tmp/badger_test", memTableSize: 2 * 1024u64)
        let mt = MemTable(opt, 1, false)
        
        @Assert(mt.shouldFlush(), false)
        
        let key1: Array<Byte> = [1u8]
        let value1: Array<Byte> = [0u8, 1u8, 2u8, 3u8, 4u8, 5u8, 6u8, 7u8]
        mt.put(key1, ValueStruct(value1))
        @Assert(mt.shouldFlush(), false)
        
        let key2: Array<Byte> = [2u8]
        let value2: Array<Byte> = Array<Byte>(2040, repeat: 0u8)
        mt.put(key2, ValueStruct(value2))
        
        @Assert(mt.shouldFlush(), true)
    }
    
    @TestCase
    func testMemTableShouldFlushByArenaUsage() {
        let opt = DBOptions(dir: "/tmp/badger_memtable_test_flush", memTableSize: 4 * 1024u64)
        let mt = MemTable(opt, 1, false)
        
        @Assert(mt.shouldFlush(), false)
        
        for (i in 0..100) {
            let key = "key_${i}".toArray()
            let value = Array<Byte>(20, repeat: 65)
            mt.put(key, ValueStruct(value))
        }
        
        @Assert(mt.shouldFlush())
        
        try {
            if (exists(Path("/tmp/badger_memtable_test_flush"))) {
                remove("/tmp/badger_memtable_test_flush", recursive: true)
            }
        } catch (e: Exception) {
        }
    }
    
    @TestCase
    func testMemTableIterator() {
        let opt = DBOptions(dir: "/tmp/badger_test")
        let mt = MemTable(opt, 0, false)
        
        let key1: Array<Byte> = [1u8]
        let value1: Array<Byte> = [10u8, 20u8]
        mt.put(key1, ValueStruct(value1))
        
        let key2: Array<Byte> = [2u8]
        let value2: Array<Byte> = [30u8, 40u8]
        mt.put(key2, ValueStruct(value2))
        
        let key3: Array<Byte> = [3u8]
        let value3: Array<Byte> = [50u8, 60u8]
        mt.put(key3, ValueStruct(value3))
        
        let iter = mt.iterator()
        var count = 0
        var keys = ArrayList<Array<Byte>>()
        var values = ArrayList<Array<Byte>>()
        
        while (iter.hasNext()) {
            if (let Some((k, v)) <- iter.next()) {
                keys.add(k)
                values.add(v.value)
                count++
            }
        }
        
        @Assert(count, 3)
        @Assert(keys[0], key1)
        @Assert(keys[1], key2)
        @Assert(keys[2], key3)
        @Assert(values[0], value1)
        @Assert(values[1], value2)
        @Assert(values[2], value3)
    }
    
    @TestCase
    func testMemTableWithExpiresAt() {
        let opt = DBOptions(dir: "/tmp/badger_test")
        let mt = MemTable(opt, 0, false)
        
        let key: Array<Byte> = [1u8, 2u8, 3u8]
        let value: Array<Byte> = [4u8, 5u8, 6u8]
        let expiresAt: UInt64 = 1234567890u64
        let vs = ValueStruct(value, expiresAt: expiresAt)
        
        mt.put(key, vs)
        
        let result = mt.get(key)
        if (let Some(v) <- result) {
            @Assert(v.value, value)
            @Assert(v.expiresAt, expiresAt)
            @Assert((v.meta & Meta.bitExpiresAt) != 0, true)
        } else {
            @Fail("Key not found")
        }
    }
    
    @TestCase
    func testMemTableWithMeta() {
        let opt = DBOptions(dir: "/tmp/badger_test")
        let mt = MemTable(opt, 0, false)
        
        let key: Array<Byte> = [1u8, 2u8, 3u8]
        let value: Array<Byte> = [4u8, 5u8, 6u8]
        let meta: Byte = Meta.bitDelete | Meta.bitDiscardEarlierVersions
        let userMeta: Byte = 0x42
        let vs = ValueStruct(value, meta: meta, userMeta: userMeta)
        
        mt.put(key, vs)
        
        let result = mt.get(key)
        if (let Some(v) <- result) {
            @Assert(v.value, value)
            @Assert(v.meta, meta)
            @Assert(v.userMeta, userMeta)
        } else {
            @Fail("Key not found")
        }
    }
    
    @TestCase
    func testIsEmpty() {
        let opt = DBOptions(dir: "/tmp/badger_test")
        let mt = MemTable(opt, 1, false)
        
        @Assert(mt.isEmpty(), true)
        
        mt.put([0x61, 0x62], ValueStruct([0x76], version: 1))
        
        @Assert(mt.isEmpty(), false)
    }
}
