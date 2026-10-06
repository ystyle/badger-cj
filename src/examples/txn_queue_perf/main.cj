package badgercj.examples.txn_queue_perf

import std.fs.*
import std.time.*
import std.collection.*
import std.sync.*
import std.convert.*
import badgercj.db.*

/**
 * 写路径同步成本基准：大量「单键小事务」并发提交。
 *
 * 每次提交都要走「投递写请求 → 写管道处理 → 唤醒提交方」的跨线程往返，
 * 事务负载刻意压到最小（单键），使测量结果主要反映提交路径的同步开销，
 * 适合用来验证队列/唤醒路径改动对写吞吐的影响。
 *
 * 输出为 RESULT 行，便于跨实现解析比对。
 */
main(args: Array<String>): Int64 {
    // 用法: txn_queue_perf [threads] [txnsPerThread] [keysPerTxn]
    // keysPerTxn 用来量化「一个事务写多个 key」对每 key 同步成本的摊薄效果
    let threads: Int64 = if (args.size > 0) { Int64.parse(args[0]) } else { 8 }
    let txnsPerThread: Int64 = if (args.size > 1) { Int64.parse(args[1]) } else { 5000 }
    let keysPerTxn: Int64 = if (args.size > 2) { Int64.parse(args[2]) } else { 1 }
    let dir = "/tmp/badger_txn_queue_perf"

    // 预热一轮：摊掉首次 mmap/文件创建/堆扩张
    let _ = runOnce(dir + "_warm", 4, 500, keysPerTxn)
    for (r in 0..3) {
        let (ns, ops) = runOnce(dir, threads, txnsPerThread, keysPerTxn)
        let keys = ops * keysPerTxn
        println("RESULT scenario=txn_queue rep=${r} threads=${threads} keys_per_txn=${keysPerTxn} txns=${ops} keys=${keys} ns=${ns} ns_per_txn=${Float64(ns) / Float64(ops)} ns_per_key=${Float64(ns) / Float64(keys)} txn_per_sec=${Float64(ops) * 1.0e9 / Float64(ns)}")
    }
    0
}

func runOnce(dir: String, threads: Int64, txnsPerThread: Int64, keysPerTxn: Int64): (Int64, Int64) {
    if (exists(dir)) {
        remove(dir, recursive: true)
    }
    let db = Badger.open(Config(dir: dir, memTableSize: 256 * 1024 * 1024))
    let futures = ArrayList<Future<Unit>>()
    let start = MonoTime.now()
    for (t in 0..threads) {
        let tid = t
        futures.add(spawn {
            for (i in 0..txnsPerThread) {
                let txn = db.newTransaction(update: true)
                for (j in 0..keysPerTxn) {
                    txn.set("k${tid}_${i}_${j}".toArray(), "v${i}_${j}".toArray())
                }
                let _ = txn.commit()
            }
        })
    }
    for (f in futures) {
        f.get()
    }
    let ns = (MonoTime.now() - start).toNanoseconds()
    db.close()
    (ns, threads * txnsPerThread)
}
