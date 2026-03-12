package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*
import std.sync.*
import std.time.*

@Test
class TxnBench {
    
    @Bench
    func benchTxnWrite100() {
        benchTxnWrite(100)
    }
    
    @Bench
    func benchTxnWrite500() {
        benchTxnWrite(500)
    }
    
    @Bench
    func benchTxnWrite1000() {
        benchTxnWrite(1000)
    }
    
    @Bench
    func benchTxnWrite2000() {
        benchTxnWrite(2000)
    }
    
    private func benchTxnWrite(keysPerTxn: Int64): Unit {
        let dir = "/tmp/badger_txn_bench"
        cleanupBenchDir(dir)
        let db = DB.open(DBOptions(dir: dir))
        
        let numTxns: Int64 = 10
        let futures = ArrayList<Future<Unit>>()
        
        for (i in 0..numTxns) {
            let fut = spawn {
                let txn = db.newTransaction(update: true)
                for (j in 0..keysPerTxn) {
                    let key = "key${i}_${j}".toArray()
                    let value = "value${i}_${j}".toArray()
                    txn.set(key, value)
                }
                txn.commit()
            }
            futures.add(fut)
        }
        
        for (fut in futures) {
            fut.get()
        }
        
        db.close()
        cleanupBenchDir(dir)
    }
}

func cleanupBenchDir(path: String): Unit {
    if (exists(Path(path))) {
        remove(Path(path), recursive: true)
    }
}