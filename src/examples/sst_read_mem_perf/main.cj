package badgercj.examples.sst_read_mem_perf

import std.fs.*
import std.time.*
import std.convert.*
import badgercj.db.*

/**
 * SSTable 读按需化对照：表数据「页缓存（mmap）」vs「GC 堆（整表读入）」。
 *
 * 用法: sst_read_mem_perf [totalMB] [mmap:on|off] [dir]
 *
 * 以 1MB 小 memtable 高频 flush，写出 totalMB 的 .sst（numLevelZeroTables 调大以隔离
 * compaction，确保表持续累积），随后随机读回。在受限堆下运行（cjHeapSize）即可直接
 * 观察两种存放方式的差异：mmap 模式表数据在页缓存、可被 OS 回收；内存模式整表常驻
 * GC 堆，数据量超过堆上限即 OOM。
 */
main(args: Array<String>): Int64 {
    let totalMB: Int64 = if (args.size > 0) { Int64.parse(args[0]) } else { 256 }
    let mmapOn: Bool = if (args.size > 1) { args[1] == "on" } else { true }
    // 注意：必须放在**真实磁盘**上。/tmp 常为 tmpfs，页缓存会直接占用内存，
    // 使「表数据在页缓存 vs 在 GC 堆」的对照失真（mmap 一侧反而更吃内存）。
    let dir = if (args.size > 2) { args[2] } else { "/tmp/badger_sst_read_mem" }
    if (exists(Path(dir))) {
        remove(Path(dir), recursive: true)
    }

    let opt = Config(dir: dir, memTableSize: 1024 * 1024u64,
        numLevelZeroTables: 100000,     // 隔离 compaction：让 L0 表持续累积
        mmapSSTable: mmapOn)
    let db = Badger.open(opt)

    let value = Array<Byte>(1024, repeat: 0x41)
    let keysPerRound: Int64 = 100
    let rounds: Int64 = totalMB * 1024 / keysPerRound      // 每轮约 100KB
    let start = MonoTime.now()
    for (r in 0..rounds) {
        let _ = db.update({ t =>
            for (j in 0..keysPerRound) {
                t.set("k${r}_${j}".toArray(), value)
            }
        })
    }
    let writeNs = (MonoTime.now() - start).toNanoseconds()

    let reads: Int64 = 20000
    let readStart = MonoTime.now()
    var hit: Int64 = 0
    for (i in 0..reads) {
        let r = (i * 7919) % rounds
        let j = (i * 31) % keysPerRound
        if (db.get("k${r}_${j}".toArray()).isSome()) {
            hit += 1
        }
    }
    let readNs = (MonoTime.now() - readStart).toNanoseconds()

    let sstCount = countSst(dir)
    println("RESULT scenario=sst_read_mem mmap=${mmapOn} totalMB=${totalMB} rounds=${rounds} " +
        "sstFiles=${sstCount} keysPerSec=${Float64(rounds * keysPerRound) * 1.0e9 / Float64(writeNs)} " +
        "readOps=${reads} hit=${hit} nsPerGet=${Float64(readNs) / Float64(reads)}")
    db.close()
    0
}

func countSst(dir: String): Int64 {
    var n: Int64 = 0
    for (e in Directory.readFrom(Path(dir))) {
        if (e.name.endsWith(".sst")) {
            n += 1
        }
    }
    n
}
