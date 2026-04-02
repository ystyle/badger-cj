package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*

@Test
class PrefixIterableTest {
    
    private func cleanupDir(dir: String): Unit {
        let path = Path(dir)
        if (exists(path)) {
            remove(path, recursive: true)
        }
    }
    
    @TestCase
    func testBasicForIn(): Unit {
        let dir = "/tmp/badger_prefix_iter_test1"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        db.update({ txn =>
            txn.set("user_alice".toArray(), "1".toArray())
            txn.set("user_bob".toArray(), "2".toArray())
            txn.set("user_charlie".toArray(), "3".toArray())
            txn.set("group_admin".toArray(), "admin".toArray())
            txn.set("group_user".toArray(), "user".toArray())
        })
        
        var count = 0
        for (_ in db.scan("user_".toArray())) {
            count++
        }
        
        @Assert(count, 3)
        
        db.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testPrefixFilter(): Unit {
        let dir = "/tmp/badger_prefix_iter_test2"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        db.update({ txn =>
            txn.set("prefix1_a".toArray(), "1".toArray())
            txn.set("prefix1_b".toArray(), "2".toArray())
            txn.set("prefix2_c".toArray(), "3".toArray())
            txn.set("prefix2_d".toArray(), "4".toArray())
        })
        
        var count1 = 0
        for (_ in db.scan("prefix1_".toArray())) {
            count1++
        }
        
        var count2 = 0
        for (_ in db.scan("prefix2_".toArray())) {
            count2++
        }
        
        @Assert(count1, 2)
        @Assert(count2, 2)
        
        db.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testNoMatch(): Unit {
        let dir = "/tmp/badger_prefix_iter_test5"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        db.update({ txn =>
            txn.set("foo".toArray(), "bar".toArray())
        })
        
        var count = 0
        for (_ in db.scan("baz_".toArray())) {
            count++
        }
        
        @Assert(count, 0)
        
        db.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testAfterClose(): Unit {
        let dir = "/tmp/badger_prefix_iter_test6"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        db.update({ txn =>
            txn.set("k1".toArray(), "v1".toArray())
            txn.set("k2".toArray(), "v2".toArray())
        })
        
        db.close()
        
        let db2 = Badger.open(opt)
        
        var count = 0
        for (_ in db2.scan("k".toArray())) {
            count++
        }
        
        @Assert(count, 2)
        
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testLargeDataset(): Unit {
        let dir = "/tmp/badger_prefix_iter_test8"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        db.update({ txn =>
            for (i in 0..100) {
                txn.set("item_${i}".toArray(), "value_${i}".toArray())
            }
        })
        
        var count = 0
        for (_ in db.scan("item_".toArray())) {
            count++
        }
        
        @Assert(count, 100)
        
        db.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testItemKeyAndValue(): Unit {
        let dir = "/tmp/badger_prefix_iter_test9"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        db.update({ txn =>
            txn.set("test_hello".toArray(), "world".toArray())
        })
        
        var found = false
        for (item in db.scan("test_".toArray())) {
            let keyOk = item.key.size > 0
            let valOk = item.value.size > 0
            let verOk = item.version > 0u64
            found = keyOk && valOk && verOk
        }
        
        @Assert(found, true)
        
        db.close()
        cleanupDir(dir)
    }
}
