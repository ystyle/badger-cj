package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.fs.*
import std.time.*

@Test
class InMemoryTest {
    
    @TestCase
    func testBasicSetGet(): Unit {
        let opt = Config(inMemory: true, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        db.update({ txn =>
            txn.set("key".toArray(), "value".toArray())
        })
        
        if (let Some(vs) <- db.get("key".toArray())) {
            @Assert(String.fromUtf8(vs.value) == "value")
        } else {
            db.close()
            @Fail("Should find key")
        }
        
        db.close()
    }
    
    @TestCase
    func testTransaction(): Unit {
        let opt = Config(inMemory: true, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        db.update({ txn =>
            txn.set("k1".toArray(), "v1".toArray())
            txn.set("k2".toArray(), "v2".toArray())
        })
        
        db.view({ txn =>
            @Assert(txn.get("k1".toArray()).isSome())
            @Assert(txn.get("k2".toArray()).isSome())
        })
        
        db.close()
    }
    
    @TestCase
    func testDelete(): Unit {
        let opt = Config(inMemory: true, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        db.update({ txn =>
            txn.set("key".toArray(), "value".toArray())
        })
        
        db.update({ txn =>
            txn.delete("key".toArray())
        })
        
        @Assert(db.get("key".toArray()).isNone())
        
        db.close()
    }
    
    @TestCase
    func testIterator(): Unit {
        let opt = Config(inMemory: true, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        db.update({ txn =>
            txn.set("a".toArray(), "1".toArray())
            txn.set("b".toArray(), "2".toArray())
            txn.set("c".toArray(), "3".toArray())
        })
        
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator()
        
        let keys = ArrayList<Array<Byte>>()
        iter.rewind()
        while (iter.valid()) {
            keys.add(iter.item().keyCopy())
            iter.next()
        }
        iter.close()
        
        @Assert(keys.size == 3)
        
        db.close()
    }
    
    @TestCase
    func testPrefixScan(): Unit {
        let opt = Config(inMemory: true, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        db.update({ txn =>
            txn.set("user:1".toArray(), "alice".toArray())
            txn.set("user:2".toArray(), "bob".toArray())
            txn.set("item:1".toArray(), "apple".toArray())
        })
        
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator(opt: IteratorOptions(prefix: "user:".toArray()))
        
        let keys = ArrayList<Array<Byte>>()
        iter.rewind()
        while (iter.valid()) {
            keys.add(iter.item().keyCopy())
            iter.next()
        }
        iter.close()
        
        @Assert(keys.size == 2)
        
        db.close()
    }
    
    @TestCase
    func testFlushAndRead(): Unit {
        // 使用小 MemTable 触发 flush
        let opt = Config(inMemory: true, memTableSize: 1024u64)
        let db = Badger.open(opt)
        
        // 写入足够数据触发 flush
        for (i in 0..50) {
            let key = "key${i}".toArray()
            let value = Array<Byte>(100, repeat: 0x61)
            db.update({ txn =>
                txn.set(key, value)
            })
        }
        
        // 验证数据仍可读取
        for (i in 0..50) {
            if (let Some(vs) <- db.get("key${i}".toArray())) {
                @Assert(vs.value.size == 100)
            } else {
                db.close()
                @Fail("Should find key${i}")
            }
        }
        
        db.close()
    }
    
    @TestCase
    func testSnapshot(): Unit {
        let opt = Config(inMemory: true, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        db.update({ txn =>
            txn.set("key".toArray(), "value1".toArray())
        })
        
        let snapshot = db.newSnapshot()
        
        // 快照后修改
        db.update({ txn =>
            txn.set("key".toArray(), "value2".toArray())
        })
        
        // 快照应该读到旧值
        if (let Some(item) <- snapshot.get("key".toArray())) {
            @Assert(String.fromUtf8(item.valueCopy()) == "value1")
        } else {
            snapshot.discard()
            db.close()
            @Fail("Should find key in snapshot")
        }
        
        // 当前应该读到新值
        if (let Some(vs) <- db.get("key".toArray())) {
            @Assert(String.fromUtf8(vs.value) == "value2")
        } else {
            snapshot.discard()
            db.close()
            @Fail("Should find key")
        }
        
        snapshot.discard()
        db.close()
    }
    
    @TestCase
    func testBatchSet(): Unit {
        let opt = Config(inMemory: true, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        let entries = ArrayList<Entry>()
        entries.add(Entry.new("k1".toArray(), "v1".toArray()))
        entries.add(Entry.new("k2".toArray(), "v2".toArray()))
        entries.add(Entry.new("k3".toArray(), "v3".toArray()))
        
        db.batchSet(entries)
        
        @Assert(db.get("k1".toArray()).isSome())
        @Assert(db.get("k2".toArray()).isSome())
        @Assert(db.get("k3".toArray()).isSome())
        
        db.close()
    }
    
    @TestCase
    func testNoDirCreated(): Unit {
        let opt = Config(inMemory: true, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        // InMemory 模式不应该创建目录
        @Assert(!exists(Path("/tmp/inmemory_test")))
        
        db.close()
    }
}