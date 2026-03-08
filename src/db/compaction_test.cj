package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import badgercj.table.*

@Test
class CompactionTest {
    @TestCase
    func testCompactionL0ToL1() {
        let opt = DBOptions(
            dir: "/tmp/badger_compaction_test1",
            memTableSize: 16 * 1024
        )
        let db = DB.open(opt)
        
        for (i in 0..30) {
            db.set("key${i}".toArray(), "value${i}".toArray())
        }
        
        db.flushMemTable()
        
        let l0Before = db.getLevelHandler(0).numTables()
        @Assert(l0Before > 0, true)
        
        db.close()
        cleanupCompactionDir("/tmp/badger_compaction_test1")
    }
    
    @TestCase
    func testCompactionPreservesData() {
        let opt = DBOptions(
            dir: "/tmp/badger_compaction_test2",
            memTableSize: 16 * 1024
        )
        let db = DB.open(opt)
        
        for (i in 0..20) {
            db.set("key${i}".toArray(), "value${i}".toArray())
        }
        
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
        let opt = DBOptions(dir: "/tmp/badger_compaction_test3")
        let db = DB.open(opt)
        
        db.set("key1".toArray(), "value1".toArray())
        db.delete("key1".toArray())
        
        db.flushMemTable()
        
        let result = db.get("key1".toArray())
        if (let Some(_) <- result) {
            @Fail("key1 should be deleted")
        }
        
        db.close()
        cleanupCompactionDir("/tmp/badger_compaction_test3")
    }
}

func cleanupCompactionDir(path: String) {
    if (exists(Path(path))) {
        remove(Path(path), recursive: true)
    }
}
