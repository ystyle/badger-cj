package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.ArrayList
import badgercj.table.*

@Test
class PersistenceTest {
    @TestCase
    func testFullLifecycleOpenWriteCloseOpenRead() {
        let dir = "/tmp/badger_lifecycle_full"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64)
        
        let db1 = Badger.open(opt)
        db1.update({ txn =>
            txn.set("key1".toArray(), "value1".toArray())
            txn.set("key2".toArray(), "value2".toArray())
        })
        db1.close()
        
        // 数据文件层验证：close 即落盘——.sst ≥1、MANIFEST 有 Create 记录、WAL 已清理
        @Assert(testCountFilesWithSuffix(dir, ".sst") > 0, true)
        @Assert(testFileBytesSize(dir + "/MANIFEST") > 0, true)
        @Assert(testCountFilesWithSuffix(dir, ".mem") == 0, true)
        
        let db2 = Badger.open(opt)
        
        @Assert(db2.get("key1".toArray()).isSome(), true)
        @Assert(db2.get("key2".toArray()).isSome(), true)
        
        db2.update({ txn =>
            txn.set("key3".toArray(), "value3".toArray())
            txn.set("key1".toArray(), "value1_updated".toArray())
        })
        db2.close()
        
        let db3 = Badger.open(opt)
        
        if (let Some(vs) <- db3.get("key1".toArray())) {
            @Assert(vs.value, "value1_updated".toArray())
        } else {
            @Fail("key1 not found")
        }
        
        @Assert(db3.get("key2".toArray()).isSome(), true)
        @Assert(db3.get("key3".toArray()).isSome(), true)
        
        db3.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testTransactionLifecycleAcrossRestarts() {
        let dir = "/tmp/badger_lifecycle_txn"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64)
        
        let db1 = Badger.open(opt)
        let txn1 = db1.newTransaction()
        txn1.set("txn_key1".toArray(), "txn_value1".toArray())
        txn1.set("txn_key2".toArray(), "txn_value2".toArray())
        txn1.commit()
        
        let txn2 = db1.newTransaction()
        txn2.delete("txn_key1".toArray())
        txn2.commit()
        
        db1.close()
        
        let db2 = Badger.open(opt)
        
        let deletedResult = db2.get("txn_key1".toArray())
        @Assert(deletedResult.isSome(), false)
        
        if (let Some(vs) <- db2.get("txn_key2".toArray())) {
            @Assert(vs.value, "txn_value2".toArray())
        } else {
            @Fail("txn_key2 not found")
        }
        
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testMultipleOpenCloseCycles() {
        let dir = "/tmp/badger_lifecycle_cycles"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64)
        
        for (cycle in 0..5) {
            let db = Badger.open(opt)
            db.updateOrThrow({ txn =>
                for (i in 0..10) {
                    txn.set("cycle${cycle}_key${i}".toArray(), "value${cycle}_${i}".toArray())
                }
            })
            db.close()
        }
        
        let finalDb = Badger.open(opt)
        
        var totalFound = 0
        for (cycle in 0..5) {
            for (i in 0..10) {
                if (finalDb.get("cycle${cycle}_key${i}".toArray()).isSome()) {
                    totalFound++
                }
            }
        }
        
        @Assert(totalFound, 50)
        finalDb.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testConcurrentLifecycle() {
        let dir = "/tmp/badger_lifecycle_concurrent"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        let futures = ArrayList<Future<Unit>>()
        for (t in 0..4) {
            let fut = spawn {
                db.updateOrThrow({ txn =>
                    for (i in 0..25) {
                        txn.set("thread${t}_key${i}".toArray(), "value${t}_${i}".toArray())
                    }
                })
            }
            futures.add(fut)
        }
        
        for (fut in futures) {
            fut.get()
        }
        
        db.close()
        
        let db2 = Badger.open(opt)
        
        var found = 0
        for (t in 0..4) {
            for (i in 0..25) {
                if (db2.get("thread${t}_key${i}".toArray()).isSome()) {
                    found++
                }
            }
        }
        
        @Assert(found, 100)
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testMemtableFlushBeforeClose() {
        let dir = "/tmp/badger_lifecycle_flush"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64)
        
        let db1 = Badger.open(opt)
        db1.update({ txn =>
            for (i in 0..100) {
                txn.set("flushkey${i}".toArray(), "flushvalue${i}".toArray())
            }
        })
        db1.close()
        
        // 数据文件层验证：close 即落盘——.sst ≥1、MANIFEST 有 Create 记录、WAL 已清理
        @Assert(testCountFilesWithSuffix(dir, ".sst") > 0, true)
        @Assert(testFileBytesSize(dir + "/MANIFEST") > 0, true)
        @Assert(testCountFilesWithSuffix(dir, ".mem") == 0, true)
        
        let db2 = Badger.open(opt)
        
        var found = 0
        for (i in 0..100) {
            if (db2.get("flushkey${i}".toArray()).isSome()) {
                found++
            }
        }
        
        @Assert(found, 100)
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testIteratorAfterReopen() {
        let dir = "/tmp/badger_iter_reopen"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64)
        
        // 写入数据
        let db1 = Badger.open(opt)
        db1.update({ txn =>
            txn.set("key1".toArray(), "value1".toArray())
            txn.set("key2".toArray(), "value2".toArray())
            txn.set("key3".toArray(), "value3".toArray())
        })
        
        // 关闭前用 iterator 验证
        let txn1 = db1.newTransaction(update: false)
        let iter1 = txn1.newIterator()
        iter1.rewind()
        var countBeforeClose = 0
        while (iter1.valid()) {
            countBeforeClose++
            iter1.next()
        }
        iter1.close()
        
        @Assert(countBeforeClose, 3)
        db1.close()
        
        // 重新打开
        let db2 = Badger.open(opt)
        
        // 用 get 验证数据存在
        @Assert(db2.get("key1".toArray()).isSome(), true)
        @Assert(db2.get("key2".toArray()).isSome(), true)
        @Assert(db2.get("key3".toArray()).isSome(), true)
        
        // 用 iterator 验证
        let txn2 = db2.newTransaction(update: false)
        let iter2 = txn2.newIterator()
        iter2.rewind()
        var countAfterReopen = 0
        while (iter2.valid()) {
            countAfterReopen++
            iter2.next()
        }
        iter2.close()
        
        @Assert(countAfterReopen, 3)
        
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testDeletePersistenceAcrossRestarts() {
        let dir = "/tmp/badger_lifecycle_delete"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64)
        
        let db1 = Badger.open(opt)
        db1.update({ txn =>
            txn.set("delkey1".toArray(), "value1".toArray())
            txn.set("delkey2".toArray(), "value2".toArray())
        })
        db1.close()
        
        let db2 = Badger.open(opt)
        db2.update({ txn => txn.delete("delkey1".toArray()) })
        db2.close()
        
        let db3 = Badger.open(opt)
        
        @Assert(db3.get("delkey1".toArray()).isSome(), false)
        @Assert(db3.get("delkey2".toArray()).isSome(), true)
        
        db3.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testOverwritePersistenceAcrossRestarts() {
        let dir = "/tmp/badger_lifecycle_overwrite"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64)
        
        let db1 = Badger.open(opt)
        db1.update({ txn => txn.set("ovkey".toArray(), "original".toArray()) })
        db1.close()
        
        let db2 = Badger.open(opt)
        db2.update({ txn => txn.set("ovkey".toArray(), "updated1".toArray()) })
        db2.close()
        
        let db3 = Badger.open(opt)
        db3.update({ txn => txn.set("ovkey".toArray(), "updated2".toArray()) })
        db3.close()
        
        let db4 = Badger.open(opt)
        if (let Some(vs) <- db4.get("ovkey".toArray())) {
            @Assert(vs.value, "updated2".toArray())
        } else {
            @Fail("ovkey not found")
        }
        db4.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testLargeValuePersistence() {
        let dir = "/tmp/badger_lifecycle_large"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64)
        let largeValue = Array<Byte>(10000, repeat: 0x41)
        
        let db1 = Badger.open(opt)
        db1.update({ txn => txn.set("largekey".toArray(), largeValue) })
        db1.close()
        
        // 数据文件层验证：value < ValueThreshold 走 LSM → close 后存在 .sst
        @Assert(testCountFilesWithSuffix(dir, ".sst") > 0, true)
        @Assert(testCountFilesWithSuffix(dir, ".mem") == 0, true)
        
        let db2 = Badger.open(opt)
        if (let Some(vs) <- db2.get("largekey".toArray())) {
            @Assert(vs.value.size, 10000)
            @Assert(vs.value[0], 0x41)
            @Assert(vs.value[9999], 0x41)
        } else {
            @Fail("largekey not found")
        }
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testEmptyDatabaseRecovery() {
        let dir = "/tmp/badger_lifecycle_empty"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64)
        
        let db1 = Badger.open(opt)
        db1.close()
        
        // 空库 close：不产生任何表文件与 MANIFEST 记录（无 Create），WAL 已清理
        @Assert(testCountFilesWithSuffix(dir, ".sst") == 0, true)
        @Assert(testFileBytesSize(dir + "/MANIFEST") == 0, true)
        @Assert(testCountFilesWithSuffix(dir, ".mem") == 0, true)
        
        let db2 = Badger.open(opt)
        @Assert(db2.get("anykey".toArray()).isSome(), false)
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testBasicPersistence() {
        let dir = "/tmp/badger_persistence_test_1"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64)
        
        let db1 = Badger.open(opt)
        db1.update({ txn =>
            txn.set("key1".toArray(), "value1".toArray())
            txn.set("key2".toArray(), "value2".toArray())
        })
        db1.close()
        
        let db2 = Badger.open(opt)
        
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
        
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64)
        
        let db1 = Badger.open(opt)
        db1.update({ txn =>
            txn.set("key1".toArray(), "value1".toArray())
            txn.set("key2".toArray(), "value2".toArray())
        })
        db1.flushWAL()
        
        let db2 = Badger.open(opt)
        
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
        
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64)
        
        let db1 = Badger.open(opt)
        db1.update({ txn => txn.set("key1".toArray(), "value1".toArray()) })
        db1.close()
        
        let db2 = Badger.open(opt)
        db2.update({ txn => txn.set("key2".toArray(), "value2".toArray()) })
        db2.close()
        
        let db3 = Badger.open(opt)
        
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
        
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64)
        
        let db1 = Badger.open(opt)
        db1.update({ txn =>
            for (i in 0..100) {
                txn.set("key${i}".toArray(), "value${i}".toArray())
            }
        })
        db1.close()
        
        let db2 = Badger.open(opt)
        
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