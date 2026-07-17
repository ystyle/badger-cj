package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*
import badgercj.table.*

@Test
class TransactionAtomicityTest {
    
    private func cleanupDir(dir: String): Unit {
        let path = Path(dir)
        if (exists(path)) {
            remove(path, recursive: true)
        }
    }
    
    @TestCase
    func testTransactionMarkerWritten(): Unit {
        let dir = "/tmp/badger_txn_marker_test"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64, syncWrites: true)
        let db = Badger.open(opt)
        
        let txn = db.newTransaction(update: true)
        txn.set("key1".toArray(), "value1".toArray())
        txn.set("key2".toArray(), "value2".toArray())
        txn.commit()
        
        db.close()
        
        let walPath = "${dir}/1.mem"
        if (exists(Path(walPath))) {
            let wal = WAL.openForRead(walPath)
            let entries = wal.readAll()
            wal.close()
            
            var hasTxnMark = false
            var hasFinMark = false
            
            for (entry in entries) {
                let vs = ValueStruct.decode(entry.value)
                if (vs.isTxnEntry()) {
                    hasTxnMark = true
                }
                if (vs.isFinTxn()) {
                    hasFinMark = true
                }
            }
            
            @Assert(hasTxnMark, true)
            @Assert(hasFinMark, true)
        }
        
        cleanupDir(dir)
    }
    
    @TestCase
    func testIncompleteTransactionDiscarded(): Unit {
        let dir = "/tmp/badger_txn_incomplete_test"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db1 = Badger.open(opt)
        
        db1.update({ txn =>
            txn.set("complete_key".toArray(), "complete_value".toArray())
        })
        db1.flushWAL()
        
        let walPath = "${dir}/1.mem"
        let wal = WAL.open(walPath)
        let incompleteVs = ValueStruct(
            "incomplete_value".toArray(),
            meta: Meta.bitTxn,
            version: 100
        )
        wal.write(keyWithTs("incomplete_key".toArray(), 100), incompleteVs.encode())
        wal.close()
        
        let db2 = Badger.open(opt)
        
        @Assert(db2.get("complete_key".toArray()).isSome(), true)
        @Assert(db2.get("incomplete_key".toArray()).isNone(), true)
        
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testCompleteTransactionRecovered(): Unit {
        let dir = "/tmp/badger_txn_complete_test"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64, syncWrites: true)
        let db1 = Badger.open(opt)
        
        db1.update({ txn =>
            txn.set("txn_key1".toArray(), "txn_value1".toArray())
            txn.set("txn_key2".toArray(), "txn_value2".toArray())
        })
        
        let db2 = Badger.open(opt)
        
        @Assert(db2.get("txn_key1".toArray()).isSome(), true)
        @Assert(db2.get("txn_key2".toArray()).isSome(), true)
        
        if (let Some(vs) <- db2.get("txn_key1".toArray())) {
            @Assert(vs.value, "txn_value1".toArray())
        }
        
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testSyncWritesDurability(): Unit {
        let dir = "/tmp/badger_sync_writes_test"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64, syncWrites: true)
        let db = Badger.open(opt)
        
        db.updateOrThrow({ txn =>
            txn.set("sync_key".toArray(), "sync_value".toArray())
        })
        
        let db2 = Badger.open(opt)
        
        @Assert(db2.get("sync_key".toArray()).isSome(), true)
        
        db2.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testMultipleTransactionsRecovery(): Unit {
        let dir = "/tmp/badger_multi_txn_test"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64, syncWrites: true)
        let db1 = Badger.open(opt)
        
        db1.update({ txn =>
            txn.set("txn1_key".toArray(), "txn1_value".toArray())
            txn.set("txn2_key".toArray(), "txn2_value".toArray())
            txn.set("txn3_key".toArray(), "txn3_value".toArray())
        })
        
        db1.close()
        
        let db2 = Badger.open(opt)
        
        @Assert(db2.get("txn1_key".toArray()).isSome(), true)
        @Assert(db2.get("txn2_key".toArray()).isSome(), true)
        @Assert(db2.get("txn3_key".toArray()).isSome(), true)
        
        db2.close()
        cleanupDir(dir)
    }
}