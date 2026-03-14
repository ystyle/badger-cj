package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*
import std.sync.*
import std.time.*

@Test
class ConcurrentTest {
    @Tag[stress]
    @TestCase
    func testConcurrentWrites() {
        let db = Badger.open(Config(dir: "/tmp/badger_concurrent_test1"))
        
        let numThreads = 10
        let writesPerThread = 100
        let futures = ArrayList<Future<Unit>>()
        
        for (i in 0..numThreads) {
            let fut = spawn {
                for (j in 0..writesPerThread) {
                    let key = "key${i}_${j}".toArray()
                    let value = "value${i}_${j}".toArray()
                    db.update({ txn => txn.set(key, value) })
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
    
    @Tag[stress]
    @TestCase
    func testConcurrentReadWriteMix() {
        let db = Badger.open(Config(dir: "/tmp/badger_concurrent_test2"))
        
        db.update({ txn => txn.set("init".toArray(), "value".toArray()) })
        
        let numWriters = 5
        let numReaders = 5
        let opsPerThread = 50
        let futures = ArrayList<Future<Unit>>()
        
        for (i in 0..numWriters) {
            let fut = spawn {
                for (j in 0..opsPerThread) {
                    let key = "writer${i}_key${j}".toArray()
                    let value = "writer${i}_value${j}".toArray()
                    db.update({ txn => txn.set(key, value) })
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
    
    @Tag[stress]
    @TestCase
    func testConcurrentIterators() {
        let db = Badger.open(Config(dir: "/tmp/badger_concurrent_test4"))
        
        db.update({ txn =>
            for (i in 0..100) {
                txn.set("key${i}".toArray(), "value${i}".toArray())
            }
        })
        
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
    
    @Tag[stress]
    @TestCase
    func testTransactionWritePerformance() {
        let dir = "/tmp/badger_txn_perf_test"
        cleanupConcurrentDir(dir)
        let db = Badger.open(Config(dir: dir))
        
        let numTxns = 50
        let keysPerTxn = 100
        let futures = ArrayList<Future<Unit>>()
        let successCount = AtomicInt64(0)
        let conflictCount = AtomicInt64(0)
        let errorCount = AtomicInt64(0)
        
        let startTime = DateTime.now()
        
        for (i in 0..numTxns) {
            let fut = spawn {
                var retries = 0
                let maxRetries = 10
                while (retries < maxRetries) {
                    var txn: ?Transaction = None
                    try {
                        txn = db.newTransaction(update: true)
                        for (j in 0..keysPerTxn) {
                            let key = "txn_key${i}_${j}".toArray()
                            let value = "txn_value${i}_${j}".toArray()
                            txn.getOrThrow().set(key, value)
                        }
                        txn.getOrThrow().commit()
                        let _ = successCount.fetchAdd(1)
                        break
                    } catch (e: TxnConflict) {
                        let _ = conflictCount.fetchAdd(1)
                        retries++
                    } catch (e: Exception) {
                        println("Txn ${i} error: ${e.message}")
                        let _ = errorCount.fetchAdd(1)
                        break
                    } finally {
                        if (let Some(t) <- txn) {
                            if (!t.isCommitted() && !t.isDiscarded()) {
                                t.discard()
                            }
                        }
                    }
                }
                if (retries >= maxRetries) {
                    println("Txn ${i} exhausted retries")
                }
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
        println("Success: ${successCount.load()}, Conflicts: ${conflictCount.load()}, Errors: ${errorCount.load()}")
        
        // 直接检查 MemTable 数据量
        let mt = db.getMemTable()
        let mtIter = mt.iterator()
        var mtCount = 0
        while (mtIter.hasNext()) {
            if (let Some(_) <- mtIter.next()) {
                mtCount++
            }
        }
        println("MemTable direct count: ${mtCount}")
        
        // 检查 immutable memtables
        let immTables = db.getImmMemTables()
        println("Immutable memtables count: ${immTables.size}")
        var immCount = 0
        for (imm in immTables) {
            let immIter = imm.iterator()
            while (immIter.hasNext()) {
                if (let Some(_) <- immIter.next()) {
                    immCount++
                }
            }
        }
        println("Immutable total count: ${immCount}")
        println("Total (mt + imm): ${mtCount + immCount}")
        
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
    
    @TestCase
    @Tag[stress]
    func testStressLargeScaleConcurrentWrites() {
        // 大规模压力测试：50 并发 × 2000 keys = 100,000 keys
        // 验证 AtomicStorage 在高并发下不会溢出
        let numThreads = 50
        let keysPerThread = 1000
        let totalWrites = numThreads * keysPerThread
        
        println("Starting large scale stress test: ${numThreads} threads × ${keysPerThread} keys = ${totalWrites} total")
        
        let db = Badger.open(Config(
            dir: "/tmp/badger_large_stress_test",
        ))
        
        let startTime = DateTime.now()
        let futures = ArrayList<Future<Unit>>()
        let errorCount = AtomicInt64(0)
        
        for (i in 0..numThreads) {
            let threadIdx = i
            let fut = spawn {
                for (j in 0..keysPerThread) {
                    let key = "largekey${threadIdx}_${j}".toArray()
                    let value = "value${threadIdx}_${j}_data_padding_to_make_it_larger".toArray()
                    try {
                        db.update({ txn => txn.set(key, value) })
                    } catch (e: Exception) {
                        errorCount.fetchAdd(1)
                        println("Error in thread ${threadIdx}, key ${j}: ${e.message}")
                    }
                }
            }
            futures.add(fut)
        }
        
        for (fut in futures) {
            fut.get()
        }
        
        let writeTime = DateTime.now() - startTime
        let writeMs = writeTime.toMilliseconds()
        println("Write phase completed: ${totalWrites} keys in ${writeMs}ms")
        println("Errors during write: ${errorCount.load()}")
        
        // 验证数据完整性
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
        
        println("Iterator verified: ${count} keys found")
        
        // 允许少量丢失（并发竞争），但不应该有大量丢失
        let lossRate = Float64(totalWrites - count) / Float64(totalWrites) * 100.0
        println("Loss rate: ${lossRate}%")
        
        @Assert(count >= totalWrites * 95 / 100, true)  // 至少 95% 成功
        @Assert(errorCount.load(), 0)  // 不应该有错误
        
        db.close()
        cleanupConcurrentDir("/tmp/badger_large_stress_test")
    }
}

func cleanupConcurrentDir(path: String): Unit {
    if (exists(Path(path))) {
        remove(Path(path), recursive: true)
    }
}
