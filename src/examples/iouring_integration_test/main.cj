package badgercj.examples.iouring_integration_test

import std.fs.*
import std.time.*
import std.collection.*
import std.sync.*
import badgercj.db.*
import badgercj.io_uring.*

main(): Int64 {
    let testDir = "/tmp/iouring_integration_test"
    
    println("=== io_uring Integration Test ===")
    println("Small MemTable + Heavy writes = Many SSTable flushes")
    println("")
    
    println("| MemTable | Writes | Sync (ms) | io_uring (ms) | Speedup | Sync keys/s | io_uring keys/s | SSTables |")
    println("|----------|--------|-----------|---------------|---------|-------------|-----------------|----------|")
    
    cleanupDir(testDir)
    let (syncMs1, sstables1) = runTest(testDir, 50000, 2 * 1024 * 1024u64, false)
    
    cleanupDir(testDir)
    let (ioUringMs1, _) = runTest(testDir, 50000, 2 * 1024 * 1024u64, true)
    
    let speedup1 = if (ioUringMs1 > 0) { Float64(syncMs1) / Float64(ioUringMs1) } else { 0.0 }
    let syncKps1 = if (syncMs1 > 0) { 50000 * 1000 / syncMs1 } else { 0 }
    let ioUringKps1 = if (ioUringMs1 > 0) { 50000 * 1000 / ioUringMs1 } else { 0 }
    println("| 2 MB | 50K | ${syncMs1} | ${ioUringMs1} | ${fmt(speedup1)}x | ${syncKps1} | ${ioUringKps1} | ${sstables1} |")
    
    cleanupDir(testDir)
    let (syncMs2, sstables2) = runTest(testDir, 100000, 2 * 1024 * 1024u64, false)
    
    cleanupDir(testDir)
    let (ioUringMs2, _) = runTest(testDir, 100000, 2 * 1024 * 1024u64, true)
    
    let speedup2 = if (ioUringMs2 > 0) { Float64(syncMs2) / Float64(ioUringMs2) } else { 0.0 }
    let syncKps2 = if (syncMs2 > 0) { 100000 * 1000 / syncMs2 } else { 0 }
    let ioUringKps2 = if (ioUringMs2 > 0) { 100000 * 1000 / ioUringMs2 } else { 0 }
    println("| 2 MB | 100K | ${syncMs2} | ${ioUringMs2} | ${fmt(speedup2)}x | ${syncKps2} | ${ioUringKps2} | ${sstables2} |")
    
    cleanupDir(testDir)
    let (syncMs3, sstables3) = runTest(testDir, 50000, 1 * 1024 * 1024u64, false)
    
    cleanupDir(testDir)
    let (ioUringMs3, _) = runTest(testDir, 50000, 1 * 1024 * 1024u64, true)
    
    let speedup3 = if (ioUringMs3 > 0) { Float64(syncMs3) / Float64(ioUringMs3) } else { 0.0 }
    let syncKps3 = if (syncMs3 > 0) { 50000 * 1000 / syncMs3 } else { 0 }
    let ioUringKps3 = if (ioUringMs3 > 0) { 50000 * 1000 / ioUringMs3 } else { 0 }
    println("| 1 MB | 50K | ${syncMs3} | ${ioUringMs3} | ${fmt(speedup3)}x | ${syncKps3} | ${ioUringKps3} | ${sstables3} |")
    
    cleanupDir(testDir)
    let (syncMs4, sstables4) = runTest(testDir, 500000, 64 * 1024 * 1024u64, false)
    
    cleanupDir(testDir)
    let (ioUringMs4, _) = runTest(testDir, 500000, 64 * 1024 * 1024u64, true)
    
    let speedup4 = if (ioUringMs4 > 0) { Float64(syncMs4) / Float64(ioUringMs4) } else { 0.0 }
    let syncKps4 = if (syncMs4 > 0) { 500000 * 1000 / syncMs4 } else { 0 }
    let ioUringKps4 = if (ioUringMs4 > 0) { 500000 * 1000 / ioUringMs4 } else { 0 }
    println("| 64 MB | 500K | ${syncMs4} | ${ioUringMs4} | ${fmt(speedup4)}x | ${syncKps4} | ${ioUringKps4} | ${sstables4} |")
    
    cleanupDir(testDir)
    let (syncMs5, sstables5) = runTest(testDir, 2000000, 256 * 1024 * 1024u64, false)
    
    cleanupDir(testDir)
    let (ioUringMs5, _) = runTest(testDir, 2000000, 256 * 1024 * 1024u64, true)
    
    let speedup5 = if (ioUringMs5 > 0) { Float64(syncMs5) / Float64(ioUringMs5) } else { 0.0 }
    let syncKps5 = if (syncMs5 > 0) { 2000000 * 1000 / syncMs5 } else { 0 }
    let ioUringKps5 = if (ioUringMs5 > 0) { 2000000 * 1000 / ioUringMs5 } else { 0 }
    println("| 256 MB | 2M | ${syncMs5} | ${ioUringMs5} | ${fmt(speedup5)}x | ${syncKps5} | ${ioUringKps5} | ${sstables5} |")
    
    cleanupDir(testDir)
    println("")
    println("=== Test Complete ===")
    
    IoUringPool.getInstance().close()
    return 0
}

func runTest(testDir: String, writeCount: Int64, memTableSize: UInt64, useIoUring: Bool): (Int64, Int64) {
    let config = Config(
        dir: testDir,
        memTableSize: memTableSize,
        disableWAL: true,
        useIoUring: useIoUring
    )
    
    let db = Badger.open(config)
    
    let startTime = MonoTime.now()
    
    let batchSize = 500
    var written: Int64 = 0
    
    while (written < writeCount) {
        let txn = db.newTransaction(update: true)
        try {
            let batchEnd = if (written + batchSize > writeCount) { writeCount } else { written + batchSize }
            
            for (i in written..batchEnd) {
                let key = "key_${i}".toArray()
                let value = "value_${i}_data_padding_128_bytes_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx".toArray()
                txn.set(key, value)
            }
            
            txn.commit()
            written = batchEnd
        } catch (e: Exception) {
            txn.discard()
            // 失败既不计入结果也不打印（written 不推进 → 持续失败会静默自旋），
            // 仅补可见性，不动循环/推进逻辑。
            println("[badger] iouring_integration_test: txn failed, written=${written}: " + e.toString())
        }
    }
    
    let elapsed = MonoTime.now() - startTime
    let ms = elapsed.toNanoseconds() / 1000000
    
    let sstableCount = countSSTables(testDir)
    
    db.close()
    
    let sstableCountAfter = countSSTables(testDir)
    
    (ms, sstableCountAfter)
}

func countSSTables(dir: String): Int64 {
    var count: Int64 = 0
    if (exists(Path(dir))) {
        for (i in 0..1000) {
            let fid = padLeft("${i}", 6)
            let path = "${dir}/${fid}.sst"
            if (exists(Path(path))) {
                count++
            }
        }
    }
    count
}

func padLeft(s: String, width: Int64): String {
    if (s.size >= width) {
        return s
    }
    let padLen = width - s.size
    let sb = StringBuilder()
    for (_ in 0..padLen) {
        sb.append('0')
    }
    sb.append(s)
    sb.toString()
}

func fmt(f: Float64): String {
    let intPart = Int64(f)
    let fracPart = Int64((f - Float64(intPart)) * 100.0)
    if (fracPart == 0) {
        return "${intPart}"
    }
    "${intPart}.${fracPart}"
}

func cleanupDir(path: String): Unit {
    if (exists(Path(path))) {
        remove(Path(path), recursive: true)
    }
}