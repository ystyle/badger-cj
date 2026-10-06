package badgercj.examples.txn_queue_perf

import std.fs.*
import std.time.*
import std.collection.*
import std.sync.*
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
main(): Int64 {
    let threads: Int64 = 8
    let txnsPerThread: Int64 = 5000
    let dir = "/tmp/badger_txn_queue_perf"

    // 预热一轮：摊掉首次 mmap/文件创建/堆扩张
    let _ = runOnce(dir + "_warm", 4, 500)
    for (r in 0..3) {
        let (ns, ops) = runOnce(dir, threads, txnsPerThread)
        println("RESULT scenario=txn_queue rep=${r} threads=${threads} txns=${ops} ns=${ns} ns_per_txn=${Float64(ns) / Float64(ops)} txn_per_sec=${Float64(ops) * 1.0e9 / Float64(ns)}")
    }
    0
}

func runOnce(dir: String, threads: Int64, txnsPerThread: Int64): (Int64, Int64) {
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
                txn.set("k${tid}_${i}".toArray(), "v${i}".toArray())
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
