package badgercj.examples.mem_profile

import std.fs.*
import std.time.*
import std.convert.*
import std.collection.*
import badgercj.db.*

// P1-2（L2 流式落盘）/ P1-4（arena 调优）测量探针。
//
// 一次进程内做一件事，输出可解析的 RESULT 行：
//   elapsedMs / mbPerSec / peakRssKB（/proc/self/status VmHWM）/ arena 已用与分配字节。
// 低堆行为由外部设 cjHeapSize 后扫描（scripts/bench/heap-sweep.py），本程序不自己调堆。
//
// 用法: mem_profile <mode> <stream> <memTableMB> <numMemtables> <totalMB> <valueBytes> <iouring>
//        [growthStartKB] [batch]
//   mode: flush             写 totalMB → 强制 flush（含 imm），报吞吐与峰值 RSS
//         compact-prepare   写两遍同范围（覆盖）+ flush → 保留数据目录（供 compact-run 用）
//         compact-run       打开既有目录 → compact()，只测压缩阶段（不写数据、不删目录）
//         arena             写 totalMB 并在每次轮换后采样 arena 利用率（P1-4）
//
// 为什么要拆 compact-prepare / compact-run：写阶段本身就有内存峰值，混在一起测不出
// 「压缩建表要多少堆」（实测：合在一起 16MB 表的用例在 256MB 堆下仍然 OOM，因为瓶颈在写阶段）。
main(args: Array<String>): Int64 {
    if (args.size < 7) {
        println("用法: mem_profile <mode:flush|compact-prepare|compact-run|arena> <stream:0|1> " +
            "<memTableMB> <numMemtables> <totalMB> <valueBytes> <iouring:0|1> [growthStartKB] [batch]")
        return 2
    }
    let mode = args[0]
    let streaming = args[1] == "1"
    let memTableMB = Int64.parse(args[2])
    let numMemtables: Int = Int64.parse(args[3])
    let totalMB = Int64.parse(args[4])
    let valueBytes = Int64.parse(args[5])
    let useIoUring = args[6] == "1"
    let growthStartKB = if (args.size > 7) { Int64.parse(args[7]) } else { 256 }
    let batch = if (args.size > 8) { Int64.parse(args[8]) } else { 100 }

    let dir = "/tmp/badger_mem_profile"
    let freshDir = mode != "compact-run"
    if (freshDir && exists(Path(dir))) {
        remove(Path(dir), recursive: true)
    }
    let opt = Config(
        dir: dir,
        memTableSize: UInt64(memTableMB) * 1024u64 * 1024u64,
        numMemtables: numMemtables,
        // flush/arena 隔离 compaction（只观测写 + flush）；compact-run 用小阈值让 L0
        // 立刻可压缩——阈值大的话 db.compact() 会因为没有候选而直接返回，测不到压缩
        numLevelZeroTables: if (mode == "compact-run") { 1 } else { 1000 },
        streamingSSTable: streaming,
        arenaGrowthStartBytes: UInt64(growthStartKB) * 1024u64,
        useIoUring: useIoUring)
    let baselineRss = peakRssKB()
    let db = Badger.open(opt)
    println("RESULT mode=${mode} phase=start baselineRssKB=${baselineRss} " +
        "rssAfterOpenKB=${peakRssKB()} firstArenaKB=${db.getMemTable().arenaCapacity() / 1024}")

    if (mode == "compact-run") {
        let tablesBefore = db.tables().size
        let rssBefore = peakRssKB()
        let compactStart = MonoTime.now()
        db.compact()
        let compactMs = (MonoTime.now() - compactStart).toNanoseconds() / 1000000
        println("RESULT mode=compact stream=${streaming} compactMs=${compactMs} " +
            "tablesBefore=${tablesBefore} tablesAfter=${db.tables().size} " +
            "rssBeforeKB=${rssBefore} peakRssKB=${peakRssKB()}")
        db.close()
        return 0
    }

    let value = Array<Byte>(valueBytes, repeat: 0x41)
    let keys = totalMB * 1024 * 1024 / (valueBytes + 16)  // 粗略：key + value + 节点元数据
    // key 预生成：逐批拼 String 会在计时区内产生大量 GC 分配，把 flush 吞吐的轮间
    // 离散度抬到 40%（实测），噪声盖过要比较的差异
    let keyList = ArrayList<Array<Byte>>()
    var ki: Int64 = 0
    while (ki < keys) {
        keyList.add(profileKey(ki))
        ki++
    }

    // arena 采样状态（P1-4）
    var maxUtil: Float64 = 0.0
    var samples: Int64 = 0
    var usedAtMax: Int64 = 0
    var arenaAtMax: Int64 = 0

    // 覆盖写遍数：compact-prepare 需要两个版本（同 key 范围写两遍）才有东西可合并
    let passes = if (mode == "compact-prepare") { 2 } else { 1 }
    var pass: Int64 = 0
    while (pass < passes) {
        let start = MonoTime.now()
        var written: Int64 = 0
        while (written < keys) {
            let base = written
            let n = if (keys - written < batch) { keys - written } else { batch }
            db.updateOrThrow({ txn =>
                var j: Int64 = 0
                while (j < n) {
                    txn.set(keyList[base + j], value)
                    j++
                }
            })
            written += n
            if (mode == "arena") {
                // 只采「有表已轮换进 imm」的时刻：此时统计里含已写满的表，利用率才有意义
                let st = db.getStats()
                if (st.ImmCount > 0 && st.MemTableArenaBytes > 0) {
                    let util = Float64(st.MemTableUsedBytes) * 100.0 / Float64(st.MemTableArenaBytes)
                    samples++
                    if (util > maxUtil) {
                        maxUtil = util
                        usedAtMax = st.MemTableUsedBytes
                        arenaAtMax = st.MemTableArenaBytes
                    }
                }
            }
        }
        let writeMs = (MonoTime.now() - start).toNanoseconds() / 1000000
        let dataMB = Float64(written * (valueBytes + 16)) / (1024.0 * 1024.0)
        println("RESULT mode=${mode} phase=write pass=${pass} stream=${streaming} mtMB=${memTableMB} " +
            "nbMem=${numMemtables} valueBytes=${valueBytes} batch=${batch} iouring=${useIoUring} " +
            "mbPerSec=${Float64(dataMB) * 1000.0 / Float64(writeMs)} elapsedMs=${writeMs} " +
            "peakRssKB=${peakRssKB()}")
        pass++
    }

    let flushStart = MonoTime.now()
    db.flushMemTable()
    let flushMs = (MonoTime.now() - flushStart).toNanoseconds() / 1000000
    let st = db.getStats()
    println("RESULT mode=${mode} phase=flush flushMs=${flushMs} flushes=${st.Flushes} " +
        "tables=${db.tables().size} arenaBytes=${st.MemTableArenaBytes} usedBytes=${st.MemTableUsedBytes} " +
        "maxBatchBytes=${st.MaxBatchBytes} peakRssKB=${peakRssKB()}")

    if (mode == "arena") {
        let target = targetArenaBytes(memTableMB)
        let batchReserve = target - memTableMB * 1024 * 1024
        println("RESULT mode=arena valueBytes=${valueBytes} mtMB=${memTableMB} batch=${batch} " +
            "samples=${samples} maxUtilPct=${maxUtil} usedAtMax=${usedAtMax} arenaAtMax=${arenaAtMax} " +
            "targetPerTable=${target} batchReserveInTarget=${batchReserve} peakRssKB=${peakRssKB()}")
    }
    db.close()
    if (mode != "compact-prepare" && exists(Path(dir))) {
        remove(Path(dir), recursive: true)
    }
    0
}

// 等宽 key（避免 user key 互为前缀的既有编码限制影响表布局）
func profileKey(i: Int64): Array<Byte> {
    let raw = i.toString()
    let pad = 12 - raw.size
    ("k" + String.fromUtf8(Array<Byte>(pad, repeat: 0x30)) + raw).toArray()
}

// 与 MemTable 内部公式一致的目标 arena（MemTableSize + 15% 批次预留 + 节点预留）
func targetArenaBytes(memTableMB: Int64): Int64 {
    let memTableSize = memTableMB * 1024 * 1024
    var maxBatchSize = memTableSize * 15 / 100
    if (maxBatchSize < 1024) {
        maxBatchSize = 1024
    }
    var maxBatchCount = maxBatchSize / 96
    if (maxBatchCount < 1) {
        maxBatchCount = 1
    }
    memTableSize + maxBatchSize + maxBatchCount * 106
}

// 峰值 RSS（Linux /proc/self/status 的 VmHWM，单位 kB；其它平台返回 0）
func peakRssKB(): Int64 {
    let p = Path("/proc/self/status")
    if (!exists(p)) {
        return 0
    }
    let text = String.fromUtf8(File.readFrom(p))
    for (line in text.split("\n")) {
        let l = line.trimAscii()
        if (!l.startsWith("VmHWM:")) {
            continue
        }
        let bytes = l.toArray()
        var num: Int64 = 0
        var seen = false
        for (b in bytes) {
            if (b >= 48 && b <= 57) {
                num = num * 10 + Int64(b - 48)
                seen = true
            } else if (seen) {
                break
            }
        }
        if (seen) {
            return num
        }
    }
    0
}
