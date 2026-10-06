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
        
        db.updateOrThrow({ txn =>
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
        
        db.updateOrThrow({ txn =>
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
        
        db.updateOrThrow({ txn =>
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
        
        db.updateOrThrow({ txn =>
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
        
        db.updateOrThrow({ txn =>
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
            db.updateOrThrow({ txn =>
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
            db.updateOrThrow({ txn =>
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
            db.updateOrThrow({ txn => txn.set("key".toArray(), "value${i}".toArray()) })
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
        
        db.updateOrThrow({ txn =>
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

    // 删除必须扛过「后续的 compaction」：tombstone 在上层、旧值在下层时，
    // 合并若把 tombstone 丢掉，下层旧值就会复活。
    // 生产实测：删掉的上游记录在某次 2MB compaction 之后整批回来（连 id 都不变）。
    @TestCase
    func testDeleteSurvivesLaterCompaction() {
        let dir = "/tmp/badger_delete_vs_compaction"
        cleanupCompactionDir(dir)
        let opt = Config(
            dir: dir,
            memTableSize: 16 * 1024u64,
            numLevelZeroTables: 2
        )
        let db = Badger.open(opt)

        // 1) 先让值沉到下层
        db.updateOrThrow({ txn =>
            txn.set("key1".toArray(), "value1".toArray())
            txn.set("key2".toArray(), "value2".toArray())
        })
        db.flushMemTable()
        db.compact()
        @Assert(db.get("key1".toArray()).isSome(), true)

        // 2) 删除：tombstone 落在上层
        db.updateOrThrow({ txn =>
            txn.delete("key1".toArray())
        })
        db.flushMemTable()
        @Assert(db.get("key1".toArray()).isNone(), true)

        // 3) 再合并一次：tombstone 与下层旧值相遇 —— 旧值不得复活
        db.compact()
        @Assert(db.get("key1".toArray()).isNone(), true)

        // 4) 重开同样不能复活
        db.close()
        let db2 = Badger.open(opt)
        @Assert(db2.get("key1".toArray()).isNone(), true)
        @Assert(db2.get("key2".toArray()).isSome(), true)
        db2.close()

        cleanupCompactionDir(dir)
    }

    // 多层 + 多轮 compaction 之后，删除仍必须生效。
    // 生产现象：删掉的上游记录在某次 2MB compaction 后整批复活（连 id 都不变），
    // 单层小场景复现不出来 —— 所以这里铺多层、多表、反复合并。
    @TestCase
    func testDeleteSurvivesMultiLevelCompactions() {
        let dir = "/tmp/badger_delete_multilevel"
        cleanupCompactionDir(dir)
        let opt = Config(dir: dir, memTableSize: 16 * 1024u64, numLevelZeroTables: 2)
        let db = Badger.open(opt)

        // 分多批写入 + flush + compact，制造多层/多表
        var i = 0
        while (i < 300) {
            let base = i
            db.updateOrThrow({ txn =>
                var j = base
                while (j < base + 20 && j < 300) {
                    txn.set("key${j}".toArray(), "value${j}".toArray())
                    j++
                }
            })
            db.flushMemTable()
            db.compact()
            i += 20
        }
        @Assert(db.get("key5".toArray()).isSome(), true)

        // 删掉其中 50 个（tombstone 与旧值分处不同层）
        db.updateOrThrow({ txn =>
            var k = 0
            while (k < 50) {
                txn.delete("key${k}".toArray())
                k++
            }
        })
        db.flushMemTable()
        @Assert(db.get("key5".toArray()).isNone(), true)

        // 继续灌数据 + 反复合并，推动后台 compaction 把不同层卷到一起
        var m = 0
        while (m < 200) {
            let base = m
            db.updateOrThrow({ txn =>
                var j = base
                while (j < base + 20 && j < 200) {
                    txn.set("newkey${j}".toArray(), "newvalue${j}".toArray())
                    j++
                }
            })
            db.flushMemTable()
            db.compact()
            m += 20
        }

        var alive = 0
        var k2 = 0
        while (k2 < 50) {
            if (db.get("key${k2}".toArray()).isSome()) {
                alive++
            }
            k2++
        }
        @Assert(alive, 0)

        db.close()
        let db2 = Badger.open(opt)
        var alive2 = 0
        var k3 = 0
        while (k3 < 50) {
            if (db2.get("key${k3}".toArray()).isSome()) {
                alive2++
            }
            k3++
        }
        @Assert(alive2, 0)
        @Assert(db2.get("key299".toArray()).isSome(), true)
        db2.close()
        cleanupCompactionDir(dir)
    }
}

func cleanupCompactionDir(path: String) {
    if (exists(Path(path))) {
        remove(Path(path), recursive: true)
    }
}
