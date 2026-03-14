package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import badgercj.table.*

@Test
class TransactionTest {
    @TestCase
    func testTransactionBasic() {
        let opt = Config(dir: "/tmp/badger_txn_test1", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        let txn = db.newTransaction()
        txn.set("key1".toArray(), "value1".toArray())
        txn.set("key2".toArray(), "value2".toArray())
        txn.commit()
        
        let result1 = db.get("key1".toArray())
        if (let Some(vs) <- result1) {
            @Assert(vs.value, "value1".toArray())
        } else {
            @Fail("key1 not found")
        }
        
        let result2 = db.get("key2".toArray())
        if (let Some(vs) <- result2) {
            @Assert(vs.value, "value2".toArray())
        } else {
            @Fail("key2 not found")
        }
        
        db.close()
        cleanupDir("/tmp/badger_txn_test1")
    }
    
    @TestCase
    func testTransactionReadYourWrites() {
        let opt = Config(dir: "/tmp/badger_txn_test2", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        db.update({ txn => txn.set("key1".toArray(), "original".toArray()) })
        
        let txn = db.newTransaction()
        txn.set("key1".toArray(), "modified".toArray())
        
        let result = txn.get("key1".toArray())
        if (let Some(value) <- result) {
            @Assert(value, "modified".toArray())
        } else {
            @Fail("key1 not found in transaction")
        }
        
        txn.commit()
        
        let resultAfterCommit = db.get("key1".toArray())
        if (let Some(vs) <- resultAfterCommit) {
            @Assert(vs.value, "modified".toArray())
        } else {
            @Fail("key1 not found after commit")
        }
        
        db.close()
        cleanupDir("/tmp/badger_txn_test2")
    }
    
    @TestCase
    func testTransactionRollback() {
        let opt = Config(dir: "/tmp/badger_txn_test3", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        db.update({ txn => txn.set("key1".toArray(), "original".toArray()) })
        
        let txn = db.newTransaction()
        txn.set("key1".toArray(), "modified".toArray())
        txn.rollback()
        
        let result = db.get("key1".toArray())
        if (let Some(vs) <- result) {
            @Assert(vs.value, "original".toArray())
        } else {
            @Fail("key1 should still exist")
        }
        
        db.close()
        cleanupDir("/tmp/badger_txn_test3")
    }
    
    @TestCase
    func testTransactionDelete() {
        let opt = Config(dir: "/tmp/badger_txn_test4", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        db.update({ txn => txn.set("key1".toArray(), "value1".toArray()) })
        
        let txn = db.newTransaction()
        txn.delete("key1".toArray())
        txn.commit()
        
        let result = db.get("key1".toArray())
        if (let Some(_) <- result) {
            @Fail("key1 should be deleted")
        }
        
        db.close()
        cleanupDir("/tmp/badger_txn_test4")
    }
    
    @TestCase
    func testTransactionMultipleCommits() {
        let opt = Config(dir: "/tmp/badger_txn_test5", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        let txn = db.newTransaction()
        txn.set("key1".toArray(), "value1".toArray())
        txn.commit()
        
        var exceptionThrown = false
        try {
            txn.commit()
        } catch (e: Exception) {
            exceptionThrown = true
        }
        
        @Assert(exceptionThrown, true)
        
        db.close()
        cleanupDir("/tmp/badger_txn_test5")
    }
    
    @TestCase
    func testTransactionNoConflictDifferentKeys() {
        let opt = Config(dir: "/tmp/badger_txn_test7", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        let txn1 = db.newTransaction(update: true)
        let _ = txn1.get("key1".toArray())
        txn1.set("key2".toArray(), "value2".toArray())
        txn1.commit()
        
        sleep(Duration.millisecond * 50)
        
        let txn2 = db.newTransaction(update: true)
        let _ = txn2.get("key3".toArray())
        txn2.set("key4".toArray(), "value4".toArray())
        
        var errorOccurred = false
        try {
            txn2.commit()
        } catch (e: Exception) {
            errorOccurred = true
        }
        
        @Assert(errorOccurred, false)
        
        db.close()
        cleanupDir("/tmp/badger_txn_test7")
    }
    
    @TestCase
    func testTransactionReadOnlyMode() {
        let opt = Config(dir: "/tmp/badger_txn_test8", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        db.update({ txn => txn.set("key1".toArray(), "value1".toArray()) })
        
        let txn = db.newTransaction(update: false)
        let result = txn.get("key1".toArray())
        
        if (let Some(value) <- result) {
            @Assert(value, "value1".toArray())
        } else {
            @Fail("key1 not found")
        }
        
        var errorCaught = false
        try {
            txn.set("key2".toArray(), "value2".toArray())
        } catch (e: Exception) {
            errorCaught = true
        }
        
        @Assert(errorCaught, true)
        
        txn.discard()
        db.close()
        cleanupDir("/tmp/badger_txn_test8")
    }
    
    @TestCase
    func testTransactionViewAPI() {
        let opt = Config(dir: "/tmp/badger_txn_test9", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        db.update({ txn => txn.set("key1".toArray(), "value1".toArray()) })
        
        let result = db.view<Array<Byte>>({ txn =>
            txn.get("key1".toArray()).getOrThrow()
        })
        
        @Assert(result, "value1".toArray())
        
        db.close()
        cleanupDir("/tmp/badger_txn_test9")
    }
    
    @TestCase
    func testTransactionUpdateAPI() {
        let opt = Config(dir: "/tmp/badger_txn_test10", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        db.update<Unit>({ txn =>
            txn.set("key1".toArray(), "value1".toArray())
        })
        
        let result = db.get("key1".toArray())
        @Assert(result.isSome(), true)
        if (let Some(vs) <- result) {
            @Assert(vs.value, "value1".toArray())
        }
        
        db.close()
        cleanupDir("/tmp/badger_txn_test10")
    }
}
