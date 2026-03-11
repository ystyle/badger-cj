package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
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
}
