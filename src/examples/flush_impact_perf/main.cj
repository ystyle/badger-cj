package badgercj.examples.flush_impact_perf

import std.env.*
import std.fs.*
import std.time.*
import std.collection.*
import badgercj.db.*

// flush 落盘语义影响专项基准（v1.6.12）：
//   小 memtable（1MB → arena 2MB）连续批量写 → 高频触发运行期 flush。
//   修复前（v1.6.10 及以前）flush 只建内存 L0 表不落盘；对齐 badger-go 后每次 flush
//   同步写 SSTable + MANIFEST（io_uring 可用自动走 io_uring，否则降级同步写）。
//   本程序用于对比新旧语义下写吞吐与 close 耗时的真实差异。
//
// 用法: flush_impact_perf [sync]     —— 传 "sync" 走降级同步写（容器 io_uring 被禁路径）
// 输出: FLUSH_IMPACT rounds=500 keys=50000 dataMB=51.2 ioUring=true elapsedMs=.. keysPerSec=..
//       FLUSH_IMPACT_CLOSE closeMs=..
main(args: Array<String>): Int64 {
    let sync = args.size > 0 && args[0] == "sync"
    let dir = "/tmp/badger_flush_impact"
    if (exists(Path(dir))) {
        remove(Path(dir), recursive: true)
    }
    let db = Badger.open(Config(
        dir: dir,
        memTableSize: 1024 * 1024u64,
        useIoUring: !sync,
        numLevelZeroTables: 1000  // 隔离 compaction：观测纯 flush 落盘路径
    ))

    let rounds = 500
    let keysPerRound = 100
    let value = Array<Byte>(1024, repeat: 0x41)  // 每轮 100KB

    let start = MonoTime.now()
    for (r in 0..rounds) {
        let entries = ArrayList<Entry>()
        for (i in 0..keysPerRound) {
            entries.add(Entry("f${r}_k${i}".toArray(), value))
        }
        db.batchSet(entries)
    }
    let elapsed = MonoTime.now() - start
    let elapsedMs = elapsed.toNanoseconds() / 1000000

    let closeStart = MonoTime.now()
    db.close()
    let closeMs = (MonoTime.now() - closeStart).toNanoseconds() / 1000000

    let totalKeys = Int64(rounds) * Int64(keysPerRound)
    let keysPerSec = totalKeys * 1000000000 / elapsed.toNanoseconds()
    let dataMB = Float64(totalKeys * 1024) / (1024.0 * 1024.0)
    println("FLUSH_IMPACT rounds=${rounds} keys=${totalKeys} dataMB=${dataMB} " +
        "ioUring=${!sync} elapsedMs=${elapsedMs} keysPerSec=${keysPerSec}")
    println("FLUSH_IMPACT_CLOSE closeMs=${closeMs}")
    if (exists(Path(dir))) {
        remove(Path(dir), recursive: true)
    }
    return 0
}
