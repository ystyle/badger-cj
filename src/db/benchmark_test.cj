package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.sync.*
import std.collection.*

@Test
class MemTableBenchmark {
    
    var db: DB = DB.open(DBOptions(dir: "/tmp/badger_bench_memtable"))
    var key: Array<Byte> = []
    var value: Array<Byte> = []
    var valueSize: Int64 = 100
    var counter: Int64 = 0
    
    @BeforeAll
    func setup() {
        cleanupBenchDir("/tmp/badger_bench_memtable")
        db = DB.open(DBOptions(dir: "/tmp/badger_bench_memtable"))
        counter = 0
    }
    
    @AfterAll
    func cleanup() {
        db.close()
        cleanupBenchDir("/tmp/badger_bench_memtable")
    }
    
    @Strategy[size in [10, 100, 1000]]
    func generateSmallData(size: Int64): Unit {
        key = "bench_key_${size}".toArray()
        value = Array<Byte>(size, repeat: 65)
        valueSize = size
    }
    
    @Bench[keySize in [10, 100]]
    func benchMemTablePut(keySize: Int64) {
        let k = "put_key_${counter}_${keySize}".toArray()
        let v = Array<Byte>(keySize, repeat: 65)
        db.set(k, v)
        counter++
        
        if (counter % 100 == 0) {
            db.close()
            cleanupBenchDir("/tmp/badger_bench_memtable")
            db = DB.open(DBOptions(dir: "/tmp/badger_bench_memtable"))
        }
    }
    
    @Bench[valueSize in [100, 1000, 10000]]
    func benchMemTablePutLargeValue(valueSize: Int64) {
        let k = "put_large_key_${counter}".toArray()
        let v = Array<Byte>(valueSize, repeat: 65)
        db.set(k, v)
        counter++
        
        if (counter % 100 == 0) {
            db.close()
            cleanupBenchDir("/tmp/badger_bench_memtable")
            db = DB.open(DBOptions(dir: "/tmp/badger_bench_memtable"))
        }
    }
    
    @Bench
    func benchMemTableGet() {
        db.get(key)
    }
    
    @Bench[keySize in [10, 100, 1000]]
    func benchMemTableGetNotFound(keySize: Int64) {
        let k = "not_exist_${keySize}".toArray()
        db.get(k)
    }
}

@Test
class TransactionBenchmark {
    
    var db: DB = DB.open(DBOptions(dir: "/tmp/badger_bench_transaction"))
    var key: Array<Byte> = []
    var value: Array<Byte> = []
    
    @BeforeAll
    func setup() {
        cleanupBenchDir("/tmp/badger_bench_transaction")
        db = DB.open(DBOptions(dir: "/tmp/badger_bench_transaction"))
        
        for (i in 0..100) {
            db.set("preload_${i}".toArray(), "value_${i}".toArray())
        }
    }
    
    @AfterAll
    func cleanup() {
        db.close()
        cleanupBenchDir("/tmp/badger_bench_transaction")
    }
    
    @Bench
    func benchNewReadOnlyTransaction() {
        let txn = db.newTransaction(update: false)
        txn.discard()
    }
    
    @Bench
    func benchNewWriteTransaction() {
        let txn = db.newTransaction(update: true)
        txn.discard()
    }
    
    @Bench[numKeys in [1, 5, 10]]
    func benchTransactionCommit(numKeys: Int64) {
        let txn = db.newTransaction(update: true)
        for (i in 0..numKeys) {
            txn.set("txn_key_${i}".toArray(), "txn_value_${i}".toArray())
        }
        txn.commit()
        txn.discard()
    }
    
    @Bench[numKeys in [1, 10, 50]]
    func benchTransactionRead(numKeys: Int64) {
        let txn = db.newTransaction(update: false)
        for (i in 0..numKeys) {
            txn.get("preload_${i % 100}".toArray())
        }
        txn.discard()
    }
}

@Test
class IteratorBenchmark {
    
    var db: DB = DB.open(DBOptions(dir: "/tmp/badger_bench_iterator"))
    
    @BeforeAll
    func setup() {
        cleanupBenchDir("/tmp/badger_bench_iterator")
        db = DB.open(DBOptions(dir: "/tmp/badger_bench_iterator"))
        
        for (i in 0..1000) {
            let keyStr = if (i < 10) { "000${i}" }
                         else if (i < 100) { "00${i}" }
                         else if (i < 1000) { "0${i}" }
                         else { "${i}" }
            db.set("iter_key_${keyStr}".toArray(), 
                   "iter_value_${i}".toArray())
        }
    }
    
    @AfterAll
    func cleanup() {
        db.close()
        cleanupBenchDir("/tmp/badger_bench_iterator")
    }
    
    @Bench[numItems in [10, 100, 1000]]
    func benchIteratorForward(numItems: Int64) {
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator()
        
        iter.rewind()
        var count: Int64 = 0
        while (iter.valid() && count < numItems) {
            count++
            iter.next()
        }
        
        iter.close()
        txn.discard()
    }
    
    @Bench[numItems in [10, 100, 1000]]
    func benchIteratorReverse(numItems: Int64) {
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator()
        
        iter.seek([255, 255, 255, 255])
        var count: Int64 = 0
        while (iter.valid() && count < numItems) {
            count++
            iter.next()
        }
        
        iter.close()
        txn.discard()
    }
    
    @Bench
    func benchIteratorSeek() {
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator()
        
        iter.seek("iter_key_0500".toArray())
        
        iter.close()
        txn.discard()
    }
}

@Test
class ConcurrentBenchmark {
    
    var db: DB = DB.open(DBOptions(dir: "/tmp/badger_bench_concurrent"))
    
    @BeforeAll
    func setup() {
        cleanupBenchDir("/tmp/badger_bench_concurrent")
        db = DB.open(DBOptions(dir: "/tmp/badger_bench_concurrent"))
    }
    
    @AfterAll
    func cleanup() {
        db.close()
        cleanupBenchDir("/tmp/badger_bench_concurrent")
    }
    
    @Bench[numThreads in [1, 2, 4, 8]]
    func benchConcurrentWrites(numThreads: Int64) {
        let futures = ArrayList<Future<Unit>>()
        
        for (i in 0..numThreads) {
            let fut = spawn {
                for (j in 0..10) {
                    let key = "concurrent_key_${i}_${j}".toArray()
                    let value = "concurrent_value_${j}".toArray()
                    db.set(key, value)
                }
            }
            futures.add(fut)
        }
        
        for (fut in futures) {
            fut.get()
        }
    }
    
    @Bench[numThreads in [1, 2, 4, 8]]
    func benchConcurrentReads(numThreads: Int64) {
        for (i in 0..100) {
            db.set("read_key_${i}".toArray(), "read_value_${i}".toArray())
        }
        
        let futures = ArrayList<Future<Unit>>()
        
        for (i in 0..numThreads) {
            let fut = spawn {
                for (j in 0..10) {
                    let key = "read_key_${j % 100}".toArray()
                    db.get(key)
                }
            }
            futures.add(fut)
        }
        
        for (fut in futures) {
            fut.get()
        }
    }
}

func cleanupBenchDir(path: String) {
    try {
        remove(path)
    } catch (e: Exception) {
    }
}
