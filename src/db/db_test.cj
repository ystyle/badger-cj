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
        let opt = Config(dir: "/tmp/badger_db_test1", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        db.updateOrThrow({ txn => txn.set("key1".toArray(), "value1".toArray()) })
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
        let opt = Config(dir: "/tmp/badger_db_test2", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        let result = db.get("nonexistent".toArray())
        if (let Some(_) <- result) {
            @Fail("Should not find non-existent key")
        }
        
        db.close()
        cleanupDir("/tmp/badger_db_test2")
    }
    
    // 删除必须跨"重开"持久：set → delete → close → reopen → get/scan 都不能再看到它。
    //
    // 为什么单独立这条：实测（cjreg 生产）"删掉的上游在容器重建后又出现"，而同进程内
    // 删除是立刻生效的 —— 典型症状就是"删除只改了内存、没落到盘上（或重开时被旧数据盖回来）"。
    // 原 testDBDelete 只验证同进程内 get 为 None，覆盖不到重开路径。
    @TestCase
    func testDeletePersistsAcrossReopen() {
        let dir = "/tmp/badger_delete_reopen_test"
        let path = Path(dir)
        if (exists(path)) {
            remove(path, recursive: true)
        }
        let db = Badger.open(Config(dir: dir, memTableSize: 1024 * 1024u64))
        db.updateOrThrow({ txn => txn.set("keep".toArray(), "v1".toArray()) })
        db.updateOrThrow({ txn => txn.set("gone".toArray(), "v2".toArray()) })
        db.updateOrThrow({ txn => txn.delete("gone".toArray()) })
        @Assert(db.get("gone".toArray()).isNone(), true)
        db.close()

        let db2 = Badger.open(Config(dir: dir, memTableSize: 1024 * 1024u64))
        @Assert(db2.get("keep".toArray()).isSome(), true)
        @Assert(db2.get("gone".toArray()).isNone(), true)
        // 扫描（前缀）也不能把删掉的键带回来 —— 上层 all<T>() 走的就是扫描
        var found = false
        for (item in db2.scan([])) {
            if (item.key == "gone".toArray()) {
                found = true
            }
        }
        @Assert(found, false)
        db2.close()
        if (exists(path)) {
            remove(path, recursive: true)
        }
    }

    @TestCase
    func testDBDelete() {
        let opt = Config(dir: "/tmp/badger_db_test3", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        db.updateOrThrow({ txn => txn.set("key1".toArray(), "value1".toArray()) })
        db.updateOrThrow({ txn => txn.delete("key1".toArray()) })
        
        let result = db.get("key1".toArray())
        if (let Some(_) <- result) {
            @Fail("Key should be deleted")
        }
        
        db.close()
        cleanupDir("/tmp/badger_db_test3")
    }
    
    @TestCase
    func testDBOverwrite() {
        let opt = Config(dir: "/tmp/badger_db_test4", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        db.updateOrThrow({ txn =>
            txn.set("key1".toArray(), "value1".toArray())
            txn.set("key1".toArray(), "value2".toArray())
        })
        
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
        let opt = Config(dir: "/tmp/badger_db_test5", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        db.updateOrThrow({ txn =>
            for (i in 0..10) {
                txn.set("key${i}".toArray(), "value${i}".toArray())
            }
        })
        
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
    
    @TestCase
    func testOpenRecovery() {
        let dir = "/tmp/badger_db_test_recovery"
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
            @Fail("Key key1 not found after recovery")
        }
        
        let v2 = db2.get("key2".toArray())
        if (let Some(vs) <- v2) {
            @Assert(vs.value, "value2".toArray())
        } else {
            @Fail("Key key2 not found after recovery")
        }
        
        db2.close()
        cleanupDir(dir)
    }
}
