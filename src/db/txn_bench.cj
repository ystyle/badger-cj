package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*

@Test
class TxnBench {
    private var db: ?Badger = None
    private let dir: String = "/tmp/badger_txn_bench"
    private var keys100: ArrayList<Array<Byte>> = ArrayList<Array<Byte>>()
    private var keys500: ArrayList<Array<Byte>> = ArrayList<Array<Byte>>()
    private var keys1000: ArrayList<Array<Byte>> = ArrayList<Array<Byte>>()
    private var value: Array<Byte> = []
    
    @BeforeAll
    func setupAll(): Unit {
        cleanupBenchDir(dir)
        db = Badger.open(Config(dir: dir, memTableSize: 256 * 1024 * 1024))
        
        value = "v".toArray()
        
        for (j in 0..100) {
            keys100.add("k${j}".toArray())
        }
        for (j in 0..500) {
            keys500.add("k${j}".toArray())
        }
        for (j in 0..1000) {
            keys1000.add("k${j}".toArray())
        }
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
        if (let Some(d) <- db) {
            let txn = d.newTransaction(update: true)
            for (key in keys100) {
                txn.set(key, value)
            }
            txn.commit()
        }
    }
    
    @Bench
    func benchTxnWrite500(): Unit {
        if (let Some(d) <- db) {
            let txn = d.newTransaction(update: true)
            for (key in keys500) {
                txn.set(key, value)
            }
            txn.commit()
        }
    }
    
    @Bench
    func benchTxnWrite1000(): Unit {
        if (let Some(d) <- db) {
            let txn = d.newTransaction(update: true)
            for (key in keys1000) {
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