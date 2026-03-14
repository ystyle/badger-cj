package badgercj.examples.perf

import std.fs.*
import std.time.*
import std.collection.*
import badgercj.db.*

main(): Int64 {
    let numThreads = 20
    let writesPerThread = 200
    let dir = "/tmp/perf_multi"
    clean(dir)
    let opt = Config(dir: dir, disableWAL: false)
    let db = Badger.open(opt)

    // Write phase
    println("=== Write Phase (20 x 200 = 4000 writes) ===")
    let startWrite = MonoTime.now()
    let futures = ArrayList<Future<Unit>>()

    for (i in 0..numThreads) {
        let idx = i
        futures.add(spawn {
            db.update({ txn =>
                for (j in 0..writesPerThread) {
                    txn.set("key${idx}_${j}".toArray(), "value${idx}_${j}".toArray())
                }
            })
        })
    }

    for (f in futures) {
        f.get()
    }
    let writeTime = MonoTime.now() - startWrite
    let totalOps = numThreads * writesPerThread
    let writeNs = writeTime.toNanoseconds()
    println("Write: ${totalOps} ops in ${writeNs / 1000000} ms, ${totalOps * 1000000000 / writeNs} ops/s, ${writeNs / totalOps} ns/op")

    // Read phase (like test verification)
    println("\n=== Read Phase (${totalOps} reads) ===")
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
    let readNs = readTime.toNanoseconds()
    println("Read: ${totalOps} ops in ${readNs / 1000000} ms, ${totalOps * 1000000000 / readNs} ops/s, ${readNs / totalOps} ns/op")

    db.close()

    try {
        clean(dir)
    } catch (e: Exception) {}

    return 0
}

func clean(dir: String): Unit {
    if (exists(dir)) {
        remove(dir, recursive: true)
    }
}
