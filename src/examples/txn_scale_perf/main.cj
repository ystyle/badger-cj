package badgercj.examples.txn_scale_perf

import std.fs.*
import std.time.*
import std.collection.*
import std.sync.*
import std.runtime.*
import badgercj.db.*

let HotKeyPool: Int64 = 100
let KeysPerTxn: Int64 = 20
let TestDuration: Duration = 5 * Duration.second

main(): Int64 {
    println("=== 抢购场景并发压测 ===")
    println("Hot key pool: ${HotKeyPool}")
    println("Keys per txn: ${KeysPerTxn}")
    println("Duration: ${TestDuration.toNanoseconds() / 1000000000}s per round")
    println("")

    let levels: Array<Int64> = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512]
    println("concurrency  txns      keys     time     keys/s      conflicts  ok")
    println("-----------  --------  -------  -------  ----------  ---------  ---")

    for (c in levels) {
        bench(c)
    }
    return 0
}

func bench(concurrency: Int64): Unit {
    let dir = "/tmp/badger_scale_${concurrency}"
    cleanupDir(dir)

    let db = Badger.open(Config(dir: dir, memTableSize: 512 * 1024 * 1024))
    let totalTxns = AtomicInt64(0)
    let totalConflicts = AtomicInt64(0)
    let ok = AtomicInt64(0)
    let done = AtomicBool(false)

    for (i in 0..HotKeyPool) {
        let key = "hot_${i}".toArray()
        let txn = db.newTransaction(update: true)
        txn.set(key, "0".toArray())
        txn.commit()
    }

    let startTime = MonoTime.now()
    let endTime = startTime + TestDuration

    let futures = ArrayList<Future<Unit>>()
    for (_ in 0..concurrency) {
        futures.add(spawn {
            while (!done.load()) {
                let txn = db.newTransaction(update: true)
                var conflict = false
                try {
                    for (j in 0..KeysPerTxn) {
                        let keyIdx = (totalTxns.load() * KeysPerTxn + j) % HotKeyPool
                        let key = "hot_${keyIdx}".toArray()

                        let _ = txn.get(key)
                        txn.set(key, "1".toArray())
                    }
                    txn.commit()
                    let _ = totalTxns.fetchAdd(1)
                    let _ = ok.fetchAdd(1)
                } catch (_e: Exception) {
                    let _ = totalConflicts.fetchAdd(1)
                    txn.discard()
                }
            }
        })
    }

    while (MonoTime.now() < endTime) {
        sleep(200 * Duration.millisecond)
    }
    done.store(true)

    for (f in futures) {
        f.get()
    }

    let ns = (MonoTime.now() - startTime).toNanoseconds()
    let txns_ = totalTxns.load()
    let conflicts_ = totalConflicts.load()
    let ok_ = ok.load()
    let totalKeys = txns_ * KeysPerTxn
    let keysPerSec = if (ns > 0) { totalKeys * 1000000000 / ns } else { 0 }

    println("${concurrency}\t\t${txns_}\t${totalKeys}\t${ns / 1000000}ms\t${keysPerSec}\t${conflicts_}\t${ok_}")

    db.close()
    cleanupDir(dir)
    gc(heavy: true)
}

func cleanupDir(path: String): Unit {
    if (exists(Path(path))) {
        remove(Path(path), recursive: true)
    }
}
