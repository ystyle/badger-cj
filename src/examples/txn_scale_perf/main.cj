package badgercj.examples.txn_scale_perf

import std.fs.*
import std.time.*
import std.collection.*
import std.sync.*
import std.runtime.*
import badgercj.db.*

let KeysPerTxn: Int64 = 1000
let ConcurrencyLevels: Array<Int64> = [1, 2, 4, 8, 16, 32, 64, 128, 256]

main(): Int64 {
    println("=== 事务并发扩展性测试 ===")
    println("Keys per txn: ${KeysPerTxn}")
    print("Concurrency levels:")
    for (c in ConcurrencyLevels) {
        print(" ${c}")
    }
    println("")
    println("")

    println("cncr    keys         time     ns/op       throughput      speedup")
    println("------  -----------  -------  ----------  --------------  -------")

    for (c in ConcurrencyLevels) {
        let ret = bench(c)
        if (ret == 0.0) {
            println("${c}      FAILED")
        }
        let _ = ret
    }

    return 0
}

func bench(concurrency: Int64): Float64 {
    let dir = "/tmp/badger_scale_${concurrency}"
    cleanupDir(dir)

    let db = Badger.open(Config(dir: dir, memTableSize: 512 * 1024 * 1024))
    let totalKeys = concurrency * KeysPerTxn
    let futures = ArrayList<Future<Unit>>()
    let successCount = AtomicInt64(0)
    let failCount = AtomicInt64(0)

    let startTime = MonoTime.now()

    for (i in 0..concurrency) {
        let idx = i
        futures.add(spawn {
            let txn = db.newTransaction(update: true)
            try {
                for (j in 0..KeysPerTxn) {
                    let key = "k${idx}_${j}".toArray()
                    let value = "v${idx}_${j}".toArray()
                    txn.set(key, value)
                }
                txn.commit()
                let _ = successCount.fetchAdd(1)
            } catch (e: Exception) {
                let _ = failCount.fetchAdd(1)
                txn.discard()
            }
        })
    }

    for (fut in futures) {
        fut.get()
    }

    let elapsed = MonoTime.now() - startTime
    let ns = elapsed.toNanoseconds()
    let ms = ns / 1000000
    let nsPerOp = ns / totalKeys
    let keysPerSec = totalKeys * 1000000000 / ns

    let ok = successCount.load()
    let fail = failCount.load()

    println("${concurrency}      ${totalKeys}  ${ms}ms  ${nsPerOp}  ${keysPerSec} keys/s  ${formatSpeedup(concurrency, keysPerSec)}")

    db.close()
    cleanupDir(dir)
    gc(heavy: true)

    if (ok != concurrency) {
        println("      WARN: ok=${ok} fail=${fail}")
        return 0.0
    }

    return Float64(keysPerSec)
}

func formatSpeedup(concurrency: Int64, keysPerSec: Int64): String {
    "${concurrency}tx"
}

func cleanupDir(path: String): Unit {
    if (exists(Path(path))) {
        remove(Path(path), recursive: true)
    }
}
