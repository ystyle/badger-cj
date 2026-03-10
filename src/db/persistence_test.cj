package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.ArrayList
import badgercj.table.*

@Test
class PersistenceTest {
    @TestCase
    func testBasicPersistence() {
        let dir = "/tmp/badger_persistence_test_1"
        cleanupDir(dir)
        
        let opt = DBOptions(dir: dir)
        
        let db1 = DB.open(opt)
        db1.set("key1".toArray(), "value1".toArray())
        db1.set("key2".toArray(), "value2".toArray())
        db1.close()
        
        let db2 = DB.open(opt)
        
        let v1 = db2.get("key1".toArray())
        if (let Some(vs) <- v1) {
            @Assert(vs.value, "value1".toArray())
        } else {
            @Fail("Key key1 not found after persistence")
        }
        
        let v2 = db2.get("key2".toArray())
        if (let Some(vs) <- v2) {
            @Assert(vs.value, "value2".toArray())
        } else {
            @Fail("Key key2 not found after persistence")
        }
        
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testCrashRecovery() {
        let dir = "/tmp/badger_persistence_test_crash"
        cleanupDir(dir)
        
        let opt = DBOptions(dir: dir)
        
        let db1 = DB.open(opt)
        db1.set("key1".toArray(), "value1".toArray())
        db1.set("key2".toArray(), "value2".toArray())
        db1.flushWAL()  // 确保 WAL 数据落盘，模拟崩溃前数据已持久化
        
        let db2 = DB.open(opt)
        
        let v1 = db2.get("key1".toArray())
        if (let Some(vs) <- v1) {
            @Assert(vs.value, "value1".toArray())
        } else {
            @Fail("Key key1 not found after crash recovery")
        }
        
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testMultipleRestarts() {
        let dir = "/tmp/badger_persistence_test_multi"
        cleanupDir(dir)
        
        let opt = DBOptions(dir: dir)
        
        let db1 = DB.open(opt)
        db1.set("key1".toArray(), "value1".toArray())
        db1.close()
        
        let db2 = DB.open(opt)
        db2.set("key2".toArray(), "value2".toArray())
        db2.close()
        
        let db3 = DB.open(opt)
        
        let v1 = db3.get("key1".toArray())
        if (let Some(vs) <- v1) {
            @Assert(vs.value, "value1".toArray())
        } else {
            @Fail("Key key1 not found after multiple restarts")
        }
        
        let v2 = db3.get("key2".toArray())
        if (let Some(vs) <- v2) {
            @Assert(vs.value, "value2".toArray())
        } else {
            @Fail("Key key2 not found after multiple restarts")
        }
        
        db3.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testLargeDataPersistence() {
        let dir = "/tmp/badger_persistence_test_large"
        cleanupDir(dir)
        
        let opt = DBOptions(dir: dir)
        
        let db1 = DB.open(opt)
        for (i in 0..100) {
            db1.set("key${i}".toArray(), "value${i}".toArray())
        }
        db1.close()
        
        let db2 = DB.open(opt)
        
        var count = 0
        for (i in 0..100) {
            let result = db2.get("key${i}".toArray())
            if (let Some(vs) <- result) {
                if (vs.value == "value${i}".toArray()) {
                    count++
                }
            }
        }
        
        @Assert(count, 100)
        
        db2.close()
        cleanupDir(dir)
    }
}
