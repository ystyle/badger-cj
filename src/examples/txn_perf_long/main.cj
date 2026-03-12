package badgercj.examples.txn_perf_long

import std.fs.*
import std.time.*
import std.collection.*
import std.sync.*
import std.runtime.*
import badgercj.db.*

main(): Int64 {
    let dir = "/tmp/badger_perf_long"
    cleanupDir(dir)
    
    let db = DB.open(DBOptions(dir: dir, memTableSize: 256 * 1024 * 1024))
    
    let numTxns = 500
    let keysPerTxn = 3000
    let futures = ArrayList<Future<Unit>>()
    let successCount = AtomicInt64(0)
    
    let startTime = MonoTime.now()
    
    for (i in 0..numTxns) {
        let idx = i
        futures.add(spawn {
            let txn = db.newTransaction(update: true)
            try {
                for (j in 0..keysPerTxn) {
                    let key = "perf_key${idx}_${j}".toArray()
                    let value = "perf_value${idx}_${j}".toArray()
                    txn.set(key, value)
                }
                txn.commit()
                let _ = successCount.fetchAdd(1)
            } catch (e: Exception) {
                txn.discard()
            }
        })
    }
    
    for (fut in futures) {
        fut.get()
    }
    
    let elapsed = MonoTime.now() - startTime
    let totalWrites = numTxns * keysPerTxn
    let ns = elapsed.toNanoseconds()
    let ms = ns / 1000000
    let keysPerSec = totalWrites * 1000000000 / ns
    
    println("WRITE: ${formatNum(numTxns)} x ${formatNum(keysPerTxn)} = ${formatNum(totalWrites)} keys in ${ms}ms, ${formatNum(keysPerSec)} keys/s (ok: ${successCount.load()})")
    
    db.close()
    cleanupDir(dir)
    return 0
}

func formatNum(n: Int64): String {
    let s = "${n}"
    let chars = s.toArray()
    let negative = chars.size > 0 && chars[0] == b'-'
    let start = if (negative) { 1 } else { 0 }
    let digits = chars.size - start
    let commaCount = (digits - 1) / 3
    if (commaCount == 0) { return s }
    
    let result = StringBuilder()
    if (negative) {
        result.append('-')
    }
    let firstGroupSize = digits % 3
    var pos = start
    if (firstGroupSize > 0) {
        for (i in 0..firstGroupSize) {
            result.append(Rune(chars[pos]))
            pos++
        }
        if (pos < chars.size) {
            result.append(',')
        }
    }
    var count = 0
    while (pos < chars.size) {
        result.append(Rune(chars[pos]))
        pos++
        count++
        if (count % 3 == 0 && pos < chars.size) {
            result.append(',')
        }
    }
    return result.toString()
}

func cleanupDir(path: String): Unit {
    if (exists(Path(path))) {
        remove(Path(path), recursive: true)
    }
}