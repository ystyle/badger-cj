package badgercj.examples.iouring_batch_test

import std.fs.*
import std.time.*
import std.collection.*
import std.sync.*
import badgercj.db.*
import badgercj.io_uring.*

main(): Int64 {
    let testDir = "/tmp/iouring_batch_test"
    
    println("=== io_uring Batch Write Test ===")
    println("High concurrency + Small MemTable = Multiple imm MemTables")
    println("")
    
    println("| MemTable | Threads | Writes | Sync (ms) | io_uring (ms) | Speedup | SSTables |")
    println("|----------|---------|--------|-----------|---------------|---------|----------|")
    
    cleanupDir(testDir)
    let (syncMs1, sstables1) = runConcurrentTest(testDir, 1 * 1024 * 1024u64, 8, 100000, false)
    
    cleanupDir(testDir)
    let (ioUringMs1, _) = runConcurrentTest(testDir, 1 * 1024 * 1024u64, 8, 100000, true)
    
    let speedup1 = if (ioUringMs1 > 0) { Float64(syncMs1) / Float64(ioUringMs1) } else { 0.0 }
    println("| 1 MB | 8 | 100K | ${syncMs1} | ${ioUringMs1} | ${fmt(speedup1)}x | ${sstables1} |")
    
    cleanupDir(testDir)
    let (syncMs2, sstables2) = runConcurrentTest(testDir, 1 * 1024 * 1024u64, 16, 200000, false)
    
    cleanupDir(testDir)
    let (ioUringMs2, _) = runConcurrentTest(testDir, 1 * 1024 * 1024u64, 16, 200000, true)
    
    let speedup2 = if (ioUringMs2 > 0) { Float64(syncMs2) / Float64(ioUringMs2) } else { 0.0 }
    println("| 1 MB | 16 | 200K | ${syncMs2} | ${ioUringMs2} | ${fmt(speedup2)}x | ${sstables2} |")
    
    cleanupDir(testDir)
    let (syncMs3, sstables3) = runConcurrentTest(testDir, 2 * 1024 * 1024u64, 8, 100000, false)
    
    cleanupDir(testDir)
    let (ioUringMs3, _) = runConcurrentTest(testDir, 2 * 1024 * 1024u64, 8, 100000, true)
    
    let speedup3 = if (ioUringMs3 > 0) { Float64(syncMs3) / Float64(ioUringMs3) } else { 0.0 }
    println("| 2 MB | 8 | 100K | ${syncMs3} | ${ioUringMs3} | ${fmt(speedup3)}x | ${sstables3} |")
    
    cleanupDir(testDir)
    println("")
    println("=== Test Complete ===")
    
    IoUringPool.getInstance().close()
    return 0
}

func runConcurrentTest(testDir: String, memTableSize: UInt64, threads: Int64, totalWrites: Int64, useIoUring: Bool): (Int64, Int64) {
    let config = Config(
        dir: testDir,
        memTableSize: memTableSize,
        disableWAL: true,
        useIoUring: useIoUring
    )
    
    let db = Badger.open(config)
    
    let writesPerThread = totalWrites / threads
    let futures = ArrayList<Future<Int64>>()
    
    let startTime = MonoTime.now()
    
    for (t in 0..threads) {
        let fut = spawn {
            try {
                let txn = db.newTransaction(update: true)
                let base = t * writesPerThread
                
                for (i in 0..writesPerThread) {
                    let key = "key_${base + i}".toArray()
                    let value = "value_${base + i}_padding_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx".toArray()
                    txn.set(key, value)
                }
                
                txn.commit()
            } catch (e: Exception) {
            }
            0
        }
        futures.add(fut)
    }
    
    for (fut in futures) {
        fut.get()
    }
    
    let elapsed = MonoTime.now() - startTime
    let ms = elapsed.toNanoseconds() / 1000000
    
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