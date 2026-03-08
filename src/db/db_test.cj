package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.ArrayList
import badgercj.table.*

@Test
class DBTest {
    @TestCase
    func testDBOpenAndClose() {
        let opt = DBOptions(dir: "/tmp/badger_db_test1")
        let db = DB.open(opt)
        
        db.set("key1".toArray(), "value1".toArray())
        let result = db.get("key1".toArray())
        
        if (let Some(vs) <- result) {
            @Assert(vs.value, "value1".toArray())
        } else {
            @Fail("Key not found")
        }
        
        db.close()
        cleanupDir("/tmp/badger_db_test1")
    }
    
    @TestCase
    func testDBGetNonExistent() {
        let opt = DBOptions(dir: "/tmp/badger_db_test2")
        let db = DB.open(opt)
        
        let result = db.get("nonexistent".toArray())
        if (let Some(_) <- result) {
            @Fail("Should not find non-existent key")
        }
        
        db.close()
        cleanupDir("/tmp/badger_db_test2")
    }
    
    @TestCase
    func testDBDelete() {
        let opt = DBOptions(dir: "/tmp/badger_db_test3")
        let db = DB.open(opt)
        
        db.set("key1".toArray(), "value1".toArray())
        db.delete("key1".toArray())
        
        let result = db.get("key1".toArray())
        if (let Some(_) <- result) {
            @Fail("Key should be deleted")
        }
        
        db.close()
        cleanupDir("/tmp/badger_db_test3")
    }
    
    @TestCase
    func testDBOverwrite() {
        let opt = DBOptions(dir: "/tmp/badger_db_test4")
        let db = DB.open(opt)
        
        db.set("key1".toArray(), "value1".toArray())
        db.set("key1".toArray(), "value2".toArray())
        
        let result = db.get("key1".toArray())
        if (let Some(vs) <- result) {
            @Assert(vs.value, "value2".toArray())
        } else {
            @Fail("Key not found")
        }
        
        db.close()
        cleanupDir("/tmp/badger_db_test4")
    }
    
    @TestCase
    func testDBMultipleKeys() {
        let opt = DBOptions(dir: "/tmp/badger_db_test5")
        let db = DB.open(opt)
        
        for (i in 0..10) {
            db.set("key${i}".toArray(), "value${i}".toArray())
        }
        
        for (i in 0..10) {
            let result = db.get("key${i}".toArray())
            if (let Some(vs) <- result) {
                @Assert(vs.value, "value${i}".toArray())
            } else {
                @Fail("Key key${i} not found")
            }
        }
        
        db.close()
        cleanupDir("/tmp/badger_db_test5")
    }
}

func cleanupDir(path: String) {
    if (exists(Path(path))) {
        remove(Path(path), recursive: true)
    }
}
