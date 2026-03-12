package badgercj.examples.perf

import std.fs.*
import std.time.*
import std.collection.*
import badgercj.db.*

main(): Int64 {
    let numThreads = 20
    let writesPerThread = 200
    
    let opt = Config(dir: "/tmp/perf_multi", disableWAL: true)
    let db = Badger.open(opt)
    
    // Write phase
    println("=== Write Phase (20 x 200 = 4000 writes) ===")
    let startWrite = MonoTime.now()
    let futures = ArrayList<Future<Unit>>()
    
    for (i in 0..numThreads) {
        let idx = i
        futures.add(spawn {
            for (j in 0..writesPerThread) {
                db.set("key${idx}_${j}".toArray(), "value${idx}_${j}".toArray())
            }
        })
    }
    
    for (f in futures) {
        f.get()
    }
    let writeTime = MonoTime.now() - startWrite
    
    println("Write time: ${writeTime.toNanoseconds() / 1000000} ms")
    println("Per write: ${writeTime.toNanoseconds() / (numThreads * writesPerThread)} ns")
    
    // Read phase (like test verification)
    println("\n=== Read Phase (4000 reads) ===")
    let startRead = MonoTime.now()
    
    let txn = db.newTransaction(update: false)
    var count = 0
    for (i in 0..numThreads) {
        for (j in 0..writesPerThread) {
            let key = "key${i}_${j}".toArray()
            if (txn.get(key).isSome()) {
                count++
            }
        }
    }
    txn.discard()
    
    let readTime = MonoTime.now() - startRead
    
    println("Read time: ${readTime.toNanoseconds() / 1000000} ms")
    println("Per read: ${readTime.toNanoseconds() / (numThreads * writesPerThread)} ns")
    println("Count: ${count}")
    
    db.close()
    
    try {
        if (exists(Path("/tmp/perf_multi"))) {
            remove(Path("/tmp/perf_multi"), recursive: true)
        }
    } catch (e: Exception) {}
    
    return 0
}
