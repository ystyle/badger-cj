package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*
import std.sync.*
import std.time.*

@Test
class ConcurrentTest {
    
    @TestCase
    func testConcurrentWrites() {
        let db = DB.open(DBOptions(dir: "/tmp/badger_concurrent_test1"))
        
        let numThreads = 10
        let writesPerThread = 100
        let futures = ArrayList<Future<Unit>>()
        
        for (i in 0..numThreads) {
            let fut = spawn {
                for (j in 0..writesPerThread) {
                    let key = "key${i}_${j}".toArray()
                    let value = "value${i}_${j}".toArray()
                    db.set(key, value)
                }
            }
            futures.add(fut)
        }
        
        for (fut in futures) {
            fut.get()
        }
        
        let txn = db.newTransaction(update: false)
        var count = 0
        for (i in 0..numThreads) {
            for (j in 0..writesPerThread) {
                let key = "key${i}_${j}".toArray()
                let val = txn.get(key)
                if (val.isSome()) {
                    count++
                }
            }
        }
        txn.discard()
        
        let expectedCount = numThreads * writesPerThread
        @Assert(count, expectedCount)
        
        db.close()
        cleanupConcurrentDir("/tmp/badger_concurrent_test1")
    }
    
    @TestCase
    func testConcurrentReadWriteMix() {
        let db = DB.open(DBOptions(dir: "/tmp/badger_concurrent_test2"))
        
        db.set("init".toArray(), "value".toArray())
        
        let numWriters = 5
        let numReaders = 5
        let opsPerThread = 50
        let futures = ArrayList<Future<Unit>>()
        
        for (i in 0..numWriters) {
            let fut = spawn {
                for (j in 0..opsPerThread) {
                    let key = "writer${i}_key${j}".toArray()
                    let value = "writer${i}_value${j}".toArray()
                    db.set(key, value)
                }
            }
            futures.add(fut)
        }
        
        for (i in 0..numReaders) {
            let fut = spawn {
                let txn = db.newTransaction(update: false)
                for (j in 0..opsPerThread) {
                    let key = "writer${j % numWriters}_key${j}".toArray()
                    txn.get(key)
                }
                txn.discard()
            }
            futures.add(fut)
        }
        
        for (fut in futures) {
            fut.get()
        }
        
        db.close()
        cleanupConcurrentDir("/tmp/badger_concurrent_test2")
    }
    
    @TestCase
    func testConcurrentTransactions() {
        let db = DB.open(DBOptions(dir: "/tmp/badger_concurrent_test3"))
        
        let numTxns = 20
        let keysPerTxn = 10
        let futures = ArrayList<Future<Unit>>()
        let counter = AtomicInt64(0)
        let conflictCounter = AtomicInt64(0)
        
        for (i in 0..numTxns) {
            let fut = spawn {
                let txn = db.newTransaction(update: true)
                
                let baseKey = "txn${i % 5}".toArray()
                txn.get(baseKey)
                
                for (j in 0..keysPerTxn) {
                    let key = "txn${i}_key${j}".toArray()
                    let value = "txn${i}_value${j}".toArray()
                    txn.set(key, value)
                }
                
                try {
                    txn.commit()
                    let _ = counter.fetchAdd(1)
                } catch (e: Exception) {
                    let _ = conflictCounter.fetchAdd(1)
                }
            }
            futures.add(fut)
        }
        
        for (fut in futures) {
            fut.get()
        }
        
        let total = counter.load() + conflictCounter.load()
        @Assert(total, numTxns)
        @Assert(counter.load() > 0)
        
        db.close()
        cleanupConcurrentDir("/tmp/badger_concurrent_test3")
    }
    
    @TestCase
    func testConcurrentIterators() {
        let db = DB.open(DBOptions(dir: "/tmp/badger_concurrent_test4"))
        
        for (i in 0..100) {
            db.set("key${i}".toArray(), "value${i}".toArray())
        }
        
        let numIterators = 5
        let futures = ArrayList<Future<Unit>>()
        let counter = AtomicInt64(0)
        
        for (i in 0..numIterators) {
            let fut = spawn {
                let txn = db.newTransaction(update: false)
                let iter = txn.newIterator()
                
                var count: Int64 = 0
                iter.rewind()
                while (iter.valid()) {
                    count++
                    iter.next()
                }
                
                iter.close()
                txn.discard()
                let _ = counter.fetchAdd(1)
            }
            futures.add(fut)
        }
        
        for (fut in futures) {
            fut.get()
        }
        
        let finalCount = counter.load()
        @Assert(finalCount, numIterators)
        
        db.close()
        cleanupConcurrentDir("/tmp/badger_concurrent_test4")
    }
    
    @TestCase
    func testStressConcurrentWrites() {
        let db = DB.open(DBOptions(dir: "/tmp/badger_concurrent_test5"))
        
        let numThreads = 20
        let writesPerThread = 200
        let futures = ArrayList<Future<Unit>>()
        
        for (i in 0..numThreads) {
            let fut = spawn {
                for (j in 0..writesPerThread) {
                    let key = "stress_key${i}_${j}".toArray()
                    let value = "stress_value${i}_${j}".toArray()
                    db.set(key, value)
                }
            }
            futures.add(fut)
        }
        
        for (fut in futures) {
            fut.get()
        }
        
        db.close()
        cleanupConcurrentDir("/tmp/badger_concurrent_test5")
    }
    
    @TestCase
    func testTransactionWritePerformance() {
        let db = DB.open(DBOptions(dir: "/tmp/badger_txn_perf_test"))
        
        let numTxns = 50
        let keysPerTxn = 100
        let futures = ArrayList<Future<Unit>>()
        let successCount = AtomicInt64(0)
        
        let startTime = DateTime.now()
        
        for (i in 0..numTxns) {
            let fut = spawn {
                let txn = db.newTransaction(update: true)
                for (j in 0..keysPerTxn) {
                    let key = "txn_key${i}_${j}".toArray()
                    let value = "txn_value${i}_${j}".toArray()
                    txn.set(key, value)
                }
                txn.commit()
                let _ = successCount.fetchAdd(1)
            }
            futures.add(fut)
        }
        
        for (fut in futures) {
            fut.get()
        }
        
        let writeTime = DateTime.now() - startTime
        let writeMs = writeTime.toMilliseconds()
        let totalWrites = numTxns * keysPerTxn
        
        println("Transaction write: ${totalWrites} keys in ${writeMs}ms (${totalWrites * 1000 / writeMs} keys/sec)")
        
        let readStartTime = DateTime.now()
        let verifyTxn = db.newTransaction(update: false)
        let iter = verifyTxn.newIterator()
        var count = 0
        iter.rewind()
        while (iter.valid()) {
            count++
            iter.next()
        }
        iter.close()
        verifyTxn.discard()
        let readTime = DateTime.now() - readStartTime
        let readMs = readTime.toMilliseconds()
        
        if (readMs > 0) {
            println("Iterator read: ${count} keys in ${readMs}ms (${count * 1000 / readMs} keys/sec)")
        } else {
            println("Iterator read: ${count} keys in <1ms (very fast!)")
        }
        
        @Assert(count, totalWrites)
        @Assert(successCount.load(), numTxns)
        
        db.close()
        cleanupConcurrentDir("/tmp/badger_txn_perf_test")
    }
}

func cleanupConcurrentDir(path: String): Unit {
        try {
        remove(path)
    } catch (e: Exception) {
    }
}
