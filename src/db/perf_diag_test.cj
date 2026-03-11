package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*
import std.sync.*
import std.time.*
import std.collection.concurrent.*

@Test
class PerfDiagTest {

    @Tag[stress]    
    @TestCase
    func testConcurrentWriteCh() {
        let writeCh = ArrayBlockingQueue<WriteRequest>(10000)
        let running = AtomicBool(true)
        
        spawn { 
            while (running.load()) {
                if (let Some(req) <- writeCh.remove(Duration.millisecond * 1)) {
                    req.done()
                }
            }
            while (writeCh.size > 0) {
                if (let Some(req) <- writeCh.tryRemove()) {
                    req.done()
                }
            }
        }
        
        let numThreads = 50
        let callsPerThread = 100
        let futures = ArrayList<Future<Unit>>()
        let start = DateTime.now()
        
        for (i in 0..numThreads) {
            let fut = spawn {
                for (j in 0..callsPerThread) {
                    let req = WriteRequest(1)
                    req.addEntry("key${i}_${j}".toArray(), "value".toArray())
                    writeCh.add(req)
                    req.wait()
                }
            }
            futures.add(fut)
        }
        
        for (fut in futures) {
            fut.get()
        }
        
        let elapsed = DateTime.now() - start
        let ms = elapsed.toMilliseconds()
        let totalCalls = numThreads * callsPerThread
        println("Concurrent WriteCh: ${totalCalls} calls in ${ms}ms")
        
        running.store(false)
        sleep(Duration.millisecond * 10)
    }
    
    @Tag[stress]
    @TestCase
    func testRealDBTransactionNoConflict() {
        let dir = "/tmp/badger_perf_noconflict"
        if (exists(Path(dir))) {
            remove(Path(dir), recursive: true)
        }
        // Disable conflict detection
        let db = DB.open(DBOptions(dir: dir, detectConflicts: false))
        
        let numTxns = 50
        let keysPerTxn = 100
        let futures = ArrayList<Future<Unit>>()
        let start = DateTime.now()
        
        for (i in 0..numTxns) {
            let fut = spawn {
                let txn = db.newTransaction(update: true)
                for (j in 0..keysPerTxn) {
                    let key = "key${i}_${j}".toArray()
                    let value = "value".toArray()
                    txn.set(key, value)
                }
                txn.commit()
            }
            futures.add(fut)
        }
        
        for (fut in futures) {
            fut.get()
        }
        
        let elapsed = DateTime.now() - start
        let ms = elapsed.toMilliseconds()
        let totalWrites = numTxns * keysPerTxn
        println("DB Transaction (no conflict detection): ${totalWrites} writes in ${ms}ms")
        
        db.close()
        if (exists(Path(dir))) {
            remove(Path(dir), recursive: true)
        }
    }
    
    @Tag[stress]
    @TestCase
    func testRealDBDirectSet() {
        let dir = "/tmp/badger_perf_direct"
        if (exists(Path(dir))) {
            remove(Path(dir), recursive: true)
        }
        let db = DB.open(DBOptions(dir: dir))
        
        let numThreads = 50
        let keysPerThread = 100
        let futures = ArrayList<Future<Unit>>()
        let start = DateTime.now()
        
        for (i in 0..numThreads) {
            let fut = spawn {
                for (j in 0..keysPerThread) {
                    let key = "key${i}_${j}".toArray()
                    let value = "value".toArray()
                    db.set(key, value)
                }
            }
            futures.add(fut)
        }
        
        for (fut in futures) {
            fut.get()
        }
        
        let elapsed = DateTime.now() - start
        let ms = elapsed.toMilliseconds()
        let totalWrites = numThreads * keysPerThread
        println("DB Direct Set: ${totalWrites} writes in ${ms}ms")
        
        db.close()
        if (exists(Path(dir))) {
            remove(Path(dir), recursive: true)
        }
    }
}