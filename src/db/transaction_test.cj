package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import badgercj.table.*

@Test
class TransactionTest {
    @TestCase
    func testTransactionBasic() {
        let opt = DBOptions(dir: "/tmp/badger_txn_test1")
        let db = DB.open(opt)
        
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
        cleanupTxnDir("/tmp/badger_txn_test1")
    }
    
    @TestCase
    func testTransactionReadYourWrites() {
        let opt = DBOptions(dir: "/tmp/badger_txn_test2")
        let db = DB.open(opt)
        
        db.set("key1".toArray(), "original".toArray())
        
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
        cleanupTxnDir("/tmp/badger_txn_test2")
    }
    
    @TestCase
    func testTransactionRollback() {
        let opt = DBOptions(dir: "/tmp/badger_txn_test3")
        let db = DB.open(opt)
        
        db.set("key1".toArray(), "original".toArray())
        
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
        cleanupTxnDir("/tmp/badger_txn_test3")
    }
    
    @TestCase
    func testTransactionDelete() {
        let opt = DBOptions(dir: "/tmp/badger_txn_test4")
        let db = DB.open(opt)
        
        db.set("key1".toArray(), "value1".toArray())
        
        let txn = db.newTransaction()
        txn.delete("key1".toArray())
        txn.commit()
        
        let result = db.get("key1".toArray())
        if (let Some(_) <- result) {
            @Fail("key1 should be deleted")
        }
        
        db.close()
        cleanupTxnDir("/tmp/badger_txn_test4")
    }
    
    @TestCase
    func testTransactionMultipleCommits() {
        let opt = DBOptions(dir: "/tmp/badger_txn_test5")
        let db = DB.open(opt)
        
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
        cleanupTxnDir("/tmp/badger_txn_test5")
    }
}

func cleanupTxnDir(path: String) {
    if (exists(Path(path))) {
        remove(Path(path), recursive: true)
    }
}
