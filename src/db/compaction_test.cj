package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.time.*
import badgercj.table.*

@Test
class CompactionTest {
    @TestCase
    func testCompactionL0ToL1() {
        let opt = Config(
            dir: "/tmp/badger_compaction_test1",
            memTableSize: 16 * 1024
        )
        let db = Badger.open(opt)
        
        db.update({ txn =>
            for (i in 0..30) {
                txn.set("key${i}".toArray(), "value${i}".toArray())
            }
        })
        
        db.flushMemTable()
        
        let l0Before = db.getLevelHandler(0).numTables()
        @Assert(l0Before > 0, true)
        
        db.close()
        cleanupCompactionDir("/tmp/badger_compaction_test1")
    }
    
    @TestCase
    func testCompactionPreservesData() {
        let opt = Config(
            dir: "/tmp/badger_compaction_test2",
            memTableSize: 16 * 1024
        )
        let db = Badger.open(opt)
        
        db.update({ txn =>
            for (i in 0..20) {
                txn.set("key${i}".toArray(), "value${i}".toArray())
            }
        })
        
        db.flushMemTable()
        
        for (i in 0..20) {
            let result = db.get("key${i}".toArray())
            if (let Some(vs) <- result) {
                @Assert(vs.value, "value${i}".toArray())
            } else {
                @Fail("key${i} not found after flush")
            }
        }
        
        db.close()
        cleanupCompactionDir("/tmp/badger_compaction_test2")
    }
    
    @TestCase
    func testCompactionDelete() {
        let opt = Config(dir: "/tmp/badger_compaction_test3", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        db.update({ txn =>
            txn.set("key1".toArray(), "value1".toArray())
            txn.delete("key1".toArray())
        })
        
        db.flushMemTable()
        
        let result = db.get("key1".toArray())
        if (let Some(_) <- result) {
            @Fail("key1 should be deleted")
        }
        
        db.close()
        cleanupCompactionDir("/tmp/badger_compaction_test3")
    }
    
    @TestCase
    func testCompactionDropTombstone() {
        let opt = Config(
            dir: "/tmp/badger_compaction_tombstone",
            memTableSize: 16 * 1024u64,
            numLevelZeroTables: 2
        )
        let db = Badger.open(opt)
        
        db.update({ txn =>
            txn.set("key1".toArray(), "value1".toArray())
            txn.set("key2".toArray(), "value2".toArray())
            txn.delete("key1".toArray())
        })
        
        db.flushMemTable()
        db.compact()
        
        @Assert(db.get("key1".toArray()).isSome(), false)
        
        if (let Some(vs) <- db.get("key2".toArray())) {
            @Assert(vs.value, "value2".toArray())
        } else {
            @Fail("key2 not found")
        }
        
        db.close()
        cleanupCompactionDir("/tmp/badger_compaction_tombstone")
    }
    
    @TestCase
    func testCompactionDropOldVersions() {
        let opt = Config(
            dir: "/tmp/badger_compaction_versions",
            memTableSize: 16 * 1024u64
        )
        let db = Badger.open(opt)
        
        db.update({ txn =>
            txn.set("key1".toArray(), "value1".toArray())
            txn.set("key1".toArray(), "value2".toArray())
            txn.set("key1".toArray(), "value3".toArray())
            txn.set("key2".toArray(), "value_a".toArray())
        })
        
        db.flushMemTable()
        db.compact()
        
        if (let Some(vs) <- db.get("key1".toArray())) {
            @Assert(vs.value, "value3".toArray())
        } else {
            @Fail("key1 not found")
        }
        
        if (let Some(vs) <- db.get("key2".toArray())) {
            @Assert(vs.value, "value_a".toArray())
        } else {
            @Fail("key2 not found")
        }
        
        db.close()
        cleanupCompactionDir("/tmp/badger_compaction_versions")
    }
    
    @TestCase
    func testManualCompact() {
        let opt = Config(
            dir: "/tmp/badger_manual_compact",
            memTableSize: 16 * 1024u64,
            numLevelZeroTables: 2
        )
        let db = Badger.open(opt)
        
        for (batch in 0..3) {
            db.update({ txn =>
                for (i in 0..20) {
                    txn.set("batch${batch}_key${i}".toArray(), "value${batch}_${i}".toArray())
                }
            })
            db.flushMemTable()
        }
        
        db.compact()
        
        var found = 0
        for (batch in 0..3) {
            for (i in 0..20) {
                if (db.get("batch${batch}_key${i}".toArray()).isSome()) {
                    found++
                }
            }
        }
        @Assert(found, 60)
        
        db.close()
        cleanupCompactionDir("/tmp/badger_manual_compact")
    }
    
    @TestCase
    func testCompactionMultipleLevels() {
        let opt = Config(
            dir: "/tmp/badger_compaction_multi_level",
            memTableSize: 16 * 1024u64,
            numLevelZeroTables: 2
        )
        let db = Badger.open(opt)
        
        for (round in 0..5) {
            db.update({ txn =>
                for (i in 0..30) {
                    txn.set("round${round}_key${i}".toArray(), "value${round}_${i}".toArray())
                }
            })
            db.flushMemTable()
            sleep(Duration.millisecond * 50)
        }
        
        db.compact()
        
        var found = 0
        for (round in 0..5) {
            for (i in 0..30) {
                if (db.get("round${round}_key${i}".toArray()).isSome()) {
                    found++
                }
            }
        }
        @Assert(found, 150)
        
        db.close()
        cleanupCompactionDir("/tmp/badger_compaction_multi_level")
    }
    
    @TestCase
    func testCompactionWithOverwrites() {
        let opt = Config(
            dir: "/tmp/badger_compaction_overwrites",
            memTableSize: 16 * 1024u64
        )
        let db = Badger.open(opt)
        
        for (i in 0..10) {
            db.update({ txn => txn.set("key".toArray(), "value${i}".toArray()) })
        }
        
        db.flushMemTable()
        db.compact()
        
        if (let Some(vs) <- db.get("key".toArray())) {
            @Assert(vs.value, "value9".toArray())
        } else {
            @Fail("key not found")
        }
        
        db.close()
        cleanupCompactionDir("/tmp/badger_compaction_overwrites")
    }
    
    @TestCase
    func testCompactionLargeDataset() {
        let opt = Config(
            dir: "/tmp/badger_compaction_large",
            memTableSize: 32 * 1024u64,
            numLevelZeroTables: 3
        )
        let db = Badger.open(opt)
        
        db.update({ txn =>
            for (i in 0..500) {
                txn.set("key${i}".toArray(), "value${i}".toArray())
            }
        })
        
        db.flushMemTable()
        db.compact()
        
        var found = 0
        for (i in 0..500) {
            if (db.get("key${i}".toArray()).isSome()) {
                found++
            }
        }
        @Assert(found, 500)
        
        db.close()
        cleanupCompactionDir("/tmp/badger_compaction_large")
    }
    
    @TestCase
    func testCompactionReopen() {
        let dir = "/tmp/badger_compaction_reopen"
        cleanupCompactionDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 16 * 1024u64)
        
        let db1 = Badger.open(opt)
        db1.update({ txn =>
            for (i in 0..50) {
                txn.set("key${i}".toArray(), "value${i}".toArray())
            }
        })
        db1.flushMemTable()
        db1.compact()
        db1.close()
        
        let db2 = Badger.open(opt)
        var found = 0
        for (i in 0..50) {
            if (db2.get("key${i}".toArray()).isSome()) {
                found++
            }
        }
        @Assert(found, 50)
        db2.close()
        
        cleanupCompactionDir(dir)
    }
}

func cleanupCompactionDir(path: String) {
    if (exists(Path(path))) {
        remove(Path(path), recursive: true)
    }
}
