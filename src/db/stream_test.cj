package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.fs.*
import std.time.*
import std.sync.*
import badgercj.table.*
import badgercj.utils.compareKeys

@Test
class StreamTest {
    
    @TestCase
    func testBasicStream(): Unit {
        let testDir = "/tmp/badger_stream_test_${DateTime.now().hashCode()}"
        StreamTest.cleanupTestDir(testDir)
        
        let config = Config(dir: testDir, memTableSize: 64 * 1024u64, disableWAL: true)
        let db = Badger.open(config)
        
        db.update { txn =>
            for (i in 0..100) {
                txn.set("key_${i}".toArray(), "value_${i}".toArray())
            }
        }
        
        let count = AtomicInt64(0)
        let stream = Stream(db)
        stream.send = { kvs =>
            count.fetchAdd(kvs.size)
        }
        stream.orchestrate()
        
        @Assert(count.load() == 100)
        
        db.close()
        StreamTest.cleanupTestDir(testDir)
    }
    
    @TestCase
    func testStreamWithPrefix(): Unit {
        let testDir = "/tmp/badger_stream_prefix_${DateTime.now().hashCode()}"
        StreamTest.cleanupTestDir(testDir)
        
        let config = Config(dir: testDir, memTableSize: 64 * 1024u64, disableWAL: true)
        let db = Badger.open(config)
        
        db.update { txn =>
            for (i in 0..50) {
                txn.set("prefix_a_${i}".toArray(), "value".toArray())
            }
            for (i in 0..50) {
                txn.set("prefix_b_${i}".toArray(), "value".toArray())
            }
        }
        
        let count = AtomicInt64(0)
        let stream = Stream(db)
        stream.prefix = "prefix_a_".toArray()
        stream.send = { kvs =>
            count.fetchAdd(kvs.size)
        }
        stream.orchestrate()
        
        @Assert(count.load() == 50)
        
        db.close()
        StreamTest.cleanupTestDir(testDir)
    }
    
    @TestCase
    func testStreamCollectAll(): Unit {
        let testDir = "/tmp/badger_stream_collect_${DateTime.now().hashCode()}"
        StreamTest.cleanupTestDir(testDir)
        
        let config = Config(dir: testDir, memTableSize: 64 * 1024u64, disableWAL: true)
        let db = Badger.open(config)
        
        db.update { txn =>
            for (i in 0..200) {
                txn.set("key_${i}".toArray(), "value_${i}_data".toArray())
            }
        }
        
        let allKVs = ArrayList<StreamKV>()
        let stream = Stream(db)
        stream.send = { kvs =>
            for (kv in kvs) {
                allKVs.add(kv)
            }
        }
        stream.orchestrate()
        
        @Assert(allKVs.size == 200)
        
        let key0 = "key_0".toArray()
        let key199 = "key_99".toArray()
        var found0 = false
        var found199 = false
        for (kv in allKVs) {
            if (compareKeys(kv.key, key0) == 0) { found0 = true }
            if (compareKeys(kv.key, key199) == 0) { found199 = true }
        }
        @Assert(found0)
        @Assert(found199)
        
        db.close()
        StreamTest.cleanupTestDir(testDir)
    }
    
    static func cleanupTestDir(path: String): Unit {
        if (exists(Path(path))) {
            remove(Path(path), recursive: true)
        }
    }
}