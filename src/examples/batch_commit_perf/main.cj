package badgercj.examples.batch_commit_perf

import std.fs.*
import std.time.*
import std.collection.*
import std.sync.*
import std.convert.*
import badgercj.db.*

/**
 * 批量写入「同步提交 vs 异步提交」基准。
 *
 * 对比 `Badger.batchSet`（投递后 `req.wait()` 等本线程）与 `Badger.batchSetAsync`
 * （投递后另起协程等待）：两者都产生一次跨线程往返，差别只在**调用方是否阻塞**。
 * 因此两种模式的计时终点统一取「数据全部写完」——否则异步模式测到的是「投递完成」，
 * 与同步模式不可比。
 *
 * 输出为 RESULT 行，便于跨实现解析比对。
 */
main(args: Array<String>): Int64 {
    // 用法: batch_commit_perf [threads] [totalKeys] [keysPerBatch] [mode:sync|async]
    let threads: Int64 = if (args.size > 0) { Int64.parse(args[0]) } else { 8 }
    let totalKeys: Int64 = if (args.size > 1) { Int64.parse(args[1]) } else { 400000 }
    let keysPerBatch: Int64 = if (args.size > 2) { Int64.parse(args[2]) } else { 64 }
    let mode: String = if (args.size > 3) { args[3] } else { "sync" }
    let dir = "/tmp/badger_batch_commit_perf"

    let _ = runOnce(dir + "_warm", threads, 8000, keysPerBatch, mode)
    for (r in 0..3) {
        let (ns, keys, failed) = runOnce(dir, threads, totalKeys, keysPerBatch, mode)
        println("RESULT scenario=batch_commit mode=${mode} batch=${keysPerBatch} threads=${threads} rep=${r} keys=${keys} failed=${failed} ns=${ns} ns_per_key=${Float64(ns) / Float64(keys)} keys_per_sec=${Float64(keys) * 1.0e9 / Float64(ns)}")
    }
    0
}

func runOnce(dir: String, threads: Int64, totalKeys: Int64, keysPerBatch: Int64, mode: String):
    (Int64, Int64, Int64) {
    if (exists(dir)) {
        remove(dir, recursive: true)
    }
    let db = Badger.open(Config(dir: dir, memTableSize: 256 * 1024 * 1024))
    let perThread = totalKeys / threads
    let batchesPerThread = perThread / keysPerBatch
    let expected = threads * batchesPerThread
    let done = AtomicInt64(0)
    let failed = AtomicInt64(0)

    let futures = ArrayList<Future<Unit>>()
    let start = MonoTime.now()
    for (t in 0..threads) {
        let tid = t
        futures.add(spawn {
            for (b in 0..batchesPerThread) {
                let entries = ArrayList<Entry>()
                for (j in 0..keysPerBatch) {
                    entries.add(Entry.new("k${tid}_${b}_${j}".toArray(), "value_${j}".toArray()))
                }
                if (mode == "async") {
                    db.batchSetAsync(entries, callback: { err =>
                        if (let Some(msg) <- err) {
                            if (failed.fetchAdd(1) == 0) {
                                println("[probe] batchSetAsync failed: " + msg)
                            }
                        }
                        done.fetchAdd(1)
                    })
                } else {
                    try {
                        db.batchSet(entries)
                    } catch (e: Exception) {
                        if (failed.fetchAdd(1) == 0) {
                            println("[probe] batchSet failed: " + e.toString())
                            e.printStackTrace()
                        }
                    }
                    done.fetchAdd(1)
                }
            }
        })
    }
    for (f in futures) {
        f.get()
    }
    // 统一终点：两种模式都等到「全部批次写入完成」
    while (done.load() < expected) {
        sleep(Duration.millisecond)
    }
    let ns = (MonoTime.now() - start).toNanoseconds()
    db.close()
    (ns, threads * batchesPerThread * keysPerBatch, failed.load())
}
