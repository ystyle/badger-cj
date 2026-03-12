package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*
import std.sync.*
import std.time.*

@Test
class TxnDebugTest {
    
    @Tag[stress]
    @TestCase[keysPerTxn in [80, 100, 120, 150, 300, 600, 1000, 2000, 3000]]
    func testLargeTxns(keysPerTxn: Int64) {
        let numTxns: Int64 = 50
        let dir = "/tmp/badger_txn_large_${keysPerTxn}"
        cleanupTxnDir(dir)
        let db = Badger.open(Config(dir: dir))
        
        let futures = ArrayList<Future<Unit>>()
        let successCount = AtomicInt64(0)
        let failCount = AtomicInt64(0)
        
        let startTime = DateTime.now()
        
        for (i in 0..numTxns) {
            let fut = spawn {
                let txn = db.newTransaction(update: true)
                try {
                    for (j in 0..keysPerTxn) {
                        let key = "txn_key${i}_${j}".toArray()
                        let value = "txn_value${i}_${j}".toArray()
                        txn.set(key, value)
                    }
                    txn.commit()
                    let _ = successCount.fetchAdd(1)
                } catch (e: Exception) {
                    let _ = failCount.fetchAdd(1)
                    txn.discard()
                }
            }
            futures.add(fut)
        }
        
        for (fut in futures) {
            fut.get()
        }
        
        let writeTime = DateTime.now() - startTime
        let totalWrites = numTxns * keysPerTxn
        println("WRITE: ${numTxns} x ${keysPerTxn} = ${totalWrites} keys in ${writeTime.toMilliseconds()}ms (ok: ${successCount.load()}, fail: ${failCount.load()})")
        
        db.close()
        cleanupTxnDir(dir)
    }
}

func cleanupTxnDir(path: String): Unit {
    if (exists(Path(path))) {
        remove(Path(path), recursive: true)
    }
}
