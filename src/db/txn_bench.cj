package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*

@Test
class TxnBench {
    private var db: ?DB = None
    private let dir: String = "/tmp/badger_txn_bench"
    
    @BeforeAll
    func setupAll(): Unit {
        cleanupBenchDir(dir)
        db = DB.open(DBOptions(dir: dir, memTableSize: 256 * 1024 * 1024))
    }
    
    @AfterAll
    func teardownAll(): Unit {
        if (let Some(d) <- db) {
            d.close()
        }
        cleanupBenchDir(dir)
    }
    
    @Bench
    func benchTxnWrite100(): Unit {
        doBench(100)
    }
    
    @Bench
    func benchTxnWrite500(): Unit {
        doBench(500)
    }
    
    @Bench
    func benchTxnWrite1000(): Unit {
        doBench(1000)
    }
    
    private func doBench(keysPerTxn: Int64): Unit {
        if (let Some(d) <- db) {
            let txn = d.newTransaction(update: true)
            for (j in 0..keysPerTxn) {
                let key = "k${j}".toArray()
                let value = "v${j}".toArray()
                txn.set(key, value)
            }
            txn.commit()
        }
    }
}

func cleanupBenchDir(path: String): Unit {
    if (exists(Path(path))) {
        remove(Path(path), recursive: true)
    }
}