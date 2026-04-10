package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*
import std.sync.*
import std.time.*
import badgercj.table.*

@Test
class CrashRecoveryTest {
    
    private func cleanupDir(dir: String): Unit {
        let path = Path(dir)
        if (exists(path)) {
            remove(path, recursive: true)
        }
    }
    
    @TestCase
    func testWalRecoveryWithoutClose() {
        let dir = "/tmp/badger_wal_recovery_test"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        
        let db1 = Badger.open(opt)
        db1.update({ txn =>
            txn.set("key1".toArray(), "value1".toArray())
            txn.set("key2".toArray(), "value2".toArray())
        })
        db1.flushWAL()
        
        let db2 = Badger.open(opt)
        
        @Assert(db2.get("key1".toArray()).isSome(), true)
        @Assert(db2.get("key2".toArray()).isSome(), true)
        
        if (let Some(vs) <- db2.get("key1".toArray())) {
            @Assert(vs.value, "value1".toArray())
        } else {
            @Fail("key1 not found")
        }
        
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testConcurrentWriteAndImmediateClose() {
        let dir = "/tmp/badger_concurrent_close_test"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        let writeCount = AtomicInt64(0)
        let stopWriting = AtomicBool(false)
        
        let writerFut = spawn {
            while (!stopWriting.load()) {
                try {
                    let c = writeCount.load()
                    db.updateOrThrow({ txn =>
                        txn.set("key${c}".toArray(), "value${c}".toArray())
                    })
                    writeCount.fetchAdd(1)
                } catch (e: Exception) {
                    break
                }
            }
        }
        
        sleep(Duration.millisecond * 50)
        
        db.close()
        stopWriting.store(true)
        
        let db2 = Badger.open(opt)
        
        let finalCount = writeCount.load()
        var found = 0
        for (i in 0..finalCount) {
            if (db2.get("key${i}".toArray()).isSome()) {
                found++
            }
        }
        
        @Assert(found > 0, true)
        
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testLargeDataFlushPerformance() {
        let dir = "/tmp/badger_flush_perf_test"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        for (batch in 0..5) {
            db.updateOrThrow({ txn =>
                for (i in 0..50) {
                    txn.set("batch${batch}_key${i}".toArray(), Array<Byte>(100, repeat: 0x41))
                }
            })
        }
        
        let start = DateTime.now()
        db.close()
        let elapsed = DateTime.now() - start
        
        @Assert(elapsed < Duration.second * 30, true)
        
        let db2 = Badger.open(opt)
        
        var found = 0
        for (batch in 0..5) {
            for (i in 0..50) {
                if (db2.get("batch${batch}_key${i}".toArray()).isSome()) {
                    found++
                }
            }
        }
        
        @Assert(found >= 200, true)
        
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testCompactorNotBlockingClose() {
        let dir = "/tmp/badger_compactor_close_test"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        for (i in 0..500) {
            db.updateOrThrow({ txn =>
                txn.set("key${i}".toArray(), "value${i}".toArray())
            })
        }
        
        let start = DateTime.now()
        db.close()
        let elapsed = DateTime.now() - start
        
        @Assert(elapsed < Duration.second * 10, true)
        
        cleanupDir(dir)
    }
    
    @TestCase
    func testMultipleWalFilesRecovery() {
        let dir = "/tmp/badger_multi_wal_test"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        
        let db1 = Badger.open(opt)
        db1.update({ txn => txn.set("key1".toArray(), "value1".toArray()) })
        db1.flushWAL()
        
        let db2 = Badger.open(opt)
        db2.update({ txn => txn.set("key2".toArray(), "value2".toArray()) })
        db2.flushWAL()
        
        let db3 = Badger.open(opt)
        
        @Assert(db3.get("key1".toArray()).isSome(), true)
        @Assert(db3.get("key2".toArray()).isSome(), true)
        
        db3.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testWriteDuringClose() {
        let dir = "/tmp/badger_write_during_close_test"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        let writeErrors = AtomicInt64(0)
        let writing = AtomicBool(true)
        
        let writerFut = spawn {
            while (writing.load()) {
                try {
                    db.updateOrThrow({ txn =>
                        txn.set("concurrent_key".toArray(), "concurrent_value".toArray())
                    })
                } catch (e: Exception) {
                    writeErrors.fetchAdd(1)
                    break
                }
            }
        }
        
        sleep(Duration.millisecond * 20)
        
        db.close()
        writing.store(false)
        
        let db2 = Badger.open(opt)
        
        let hasData = db2.get("concurrent_key".toArray()).isSome()
        
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testForceCloseDuringCompaction() {
        let dir = "/tmp/badger_force_close_test"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        for (i in 0..200) {
            db.updateOrThrow({ txn =>
                txn.set("force_key${i}".toArray(), Array<Byte>(200, repeat: 0x42))
            })
        }
        
        let closeFut = spawn {
            db.close()
        }
        
        let result = closeFut.get(Duration.second * 15)
        
        let db2 = Badger.open(opt)
        var found = 0
        for (i in 0..200) {
            if (db2.get("force_key${i}".toArray()).isSome()) {
                found++
            }
        }
        
        @Assert(found > 0, true)
        
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testIteratorAfterCrashRecovery() {
        let dir = "/tmp/badger_iter_crash_test"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        
        let db1 = Badger.open(opt)
        db1.update({ txn =>
            for (i in 0..20) {
                txn.set("iter_key${i}".toArray(), "iter_value${i}".toArray())
            }
        })
        db1.flushWAL()
        
        let db2 = Badger.open(opt)
        
        let txn = db2.newTransaction(update: false)
        let iter = txn.newIterator()
        iter.rewind()
        
        var count = 0
        while (iter.valid()) {
            count++
            iter.next()
        }
        iter.close()
        
        @Assert(count, 20)
        
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testPartialWriteRecovery() {
        let dir = "/tmp/badger_partial_write_test"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        
        let db1 = Badger.open(opt)
        db1.update({ txn =>
            txn.set("partial_key1".toArray(), "partial_value1".toArray())
        })
        db1.flushWAL()
        
        db1.update({ txn =>
            txn.set("partial_key2".toArray(), "partial_value2".toArray())
        })
        
        let db2 = Badger.open(opt)
        
        @Assert(db2.get("partial_key1".toArray()).isSome(), true)
        
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testCloseIdempotency() {
        let dir = "/tmp/badger_close_idempotent_test"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        db.updateOrThrow({ txn =>
            txn.set("idempotent_key".toArray(), "idempotent_value".toArray())
        })
        
        db.close()
        
        let db2 = Badger.open(opt)
        @Assert(db2.get("idempotent_key".toArray()).isSome(), true)
        db2.close()
        
        cleanupDir(dir)
    }
    
    @TestCase
    func testCloseIsIdempotent() {
        let dir = "/tmp/badger_close_multi_test"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        db.updateOrThrow({ txn =>
            txn.set("multi_close_key".toArray(), "multi_close_value".toArray())
        })
        
        // 多次调用 close() 应该是安全的
        db.close()
        db.close()
        db.close()
        
        let db2 = Badger.open(opt)
        @Assert(db2.get("multi_close_key".toArray()).isSome(), true)
        db2.close()
        
        cleanupDir(dir)
    }
    
    @TestCase
    func testAutoCloseOnExitDefaultDisabled() {
        let opt = Config(dir: "/tmp/test", memTableSize: 64 * 1024u64)
        @Assert(opt.AutoCloseOnExit, false)
    }
    
    @TestCase
    func testAutoCloseOnExitCanBeEnabled() {
        let opt = Config(dir: "/tmp/test", memTableSize: 64 * 1024u64, autoCloseOnExit: true)
        @Assert(opt.AutoCloseOnExit, true)
    }
    
    @TestCase
    func testWithAutoCloseOnExit() {
        let opt1 = Config(dir: "/tmp/test", memTableSize: 64 * 1024u64)
        @Assert(opt1.AutoCloseOnExit, false)
        
        let opt2 = opt1.withAutoCloseOnExit(true)
        @Assert(opt2.AutoCloseOnExit, true)
        
        let opt3 = opt2.withAutoCloseOnExit(false)
        @Assert(opt3.AutoCloseOnExit, false)
    }
}