package badgercj.examples.sstable_write_perf

import std.fs.*
import std.time.*
import std.collection.*
import std.sync.*
import badgercj.table.*
import badgercj.db.*
import badgercj.io_uring.*

main(): Int64 {
    let testDir = "/tmp/sstable_batch_write_${DateTime.now().hashCode()}"
    Directory.create(Path(testDir), recursive: true)
    
    println("=== Batch SSTable Write: Sync vs io_uring (optimized) ===")
    println("Using IoUringPool for batch writes")
    println("")
    
    let fileCounts = [4, 8, 16, 32]
    let fileSize = 4 * 1024 * 1024
    
    println("| Files | File Size | Sync (ms) | io_uring Batch (ms) | Speedup | Sync MB/s | io_uring MB/s |")
    println("|-------|-----------|-----------|---------------------|---------|-----------|---------------|")
    
    for (numFiles in fileCounts) {
        let (syncMs, ioUringMs, totalMB) = runBatchTest(testDir, numFiles, fileSize)
        let speedup = if (ioUringMs > 0) { Float64(syncMs) / Float64(ioUringMs) } else { 0.0 }
        let syncThroughput = if (syncMs > 0) { totalMB * 1000.0 / Float64(syncMs) } else { 0.0 }
        let ioUringThroughput = if (ioUringMs > 0) { totalMB * 1000.0 / Float64(ioUringMs) } else { 0.0 }
        println("| ${numFiles} | 4 MB | ${syncMs} | ${ioUringMs} | ${formatFloat(speedup, 2)}x | ${formatFloat(syncThroughput, 0)} | ${formatFloat(ioUringThroughput, 0)} |")
    }
    
    println("")
    println("=== Sequential Write (baseline) ===")
    println("")
    
    println("| Files | File Size | Sync (ms) | io_uring Single (ms) | Speedup |")
    println("|-------|-----------|-----------|----------------------|---------|")
    
    for (numFiles in fileCounts) {
        let (syncMs, ioUringMs, _) = runSequentialTest(testDir, numFiles, fileSize)
        let speedup = if (ioUringMs > 0) { Float64(syncMs) / Float64(ioUringMs) } else { 0.0 }
        println("| ${numFiles} | 4 MB | ${syncMs} | ${ioUringMs} | ${formatFloat(speedup, 2)}x |")
    }
    
    println("")
    println("=== Test Complete ===")
    
    IoUringPool.getInstance().close()
    cleanupDir(testDir)
    return 0
}

func formatFloat(f: Float64, decimals: Int64): String {
    if (decimals <= 0) {
        return "${Int64(f)}"
    }
    let intPart = Int64(f)
    let fracPart = Int64((f - Float64(intPart)) * 100.0)
    "${intPart}.${fracPart}"
}

func runBatchTest(testDir: String, numFiles: Int64, fileSize: Int64): (Int64, Int64, Float64) {
    let data = generateSSTableData(fileSize)
    let totalBytes = Float64(numFiles * data.size)
    let totalMB = totalBytes / (1024.0 * 1024.0)
    
    var syncMs: Int64 = 0
    var ioUringMs: Int64 = 0
    
    for (round in 0..5) {
        let syncDir = "${testDir}/sync_${round}"
        let ioUringDir = "${testDir}/iouring_${round}"
        Directory.create(Path(syncDir), recursive: true)
        Directory.create(Path(ioUringDir), recursive: true)
        
        let t1 = MonoTime.now()
        let syncRequests = ArrayList<FileWriteRequest>()
        for (i in 0..numFiles) {
            syncRequests.add(FileWriteRequest("${syncDir}/${i}.sst", data))
        }
        writeFilesBatch(syncRequests, useIoUring: false)
        let t2 = MonoTime.now()
        let thisSyncMs = (t2 - t1).toNanoseconds() / 1000000
        if (thisSyncMs > syncMs) { syncMs = thisSyncMs }
        
        let t3 = MonoTime.now()
        let ioUringRequests = ArrayList<FileWriteRequest>()
        for (i in 0..numFiles) {
            ioUringRequests.add(FileWriteRequest("${ioUringDir}/${i}.sst", data))
        }
        writeFilesBatch(ioUringRequests, useIoUring: true)
        let t4 = MonoTime.now()
        let thisIoUringMs = (t4 - t3).toNanoseconds() / 1000000
        if (thisIoUringMs > ioUringMs) { ioUringMs = thisIoUringMs }
        
        cleanupDir(syncDir)
        cleanupDir(ioUringDir)
    }
    
    (syncMs, ioUringMs, totalMB)
}

func runSequentialTest(testDir: String, numFiles: Int64, fileSize: Int64): (Int64, Int64, Float64) {
    let data = generateSSTableData(fileSize)
    let totalBytes = Float64(numFiles * data.size)
    let totalMB = totalBytes / (1024.0 * 1024.0)
    
    var syncMs: Int64 = 0
    var ioUringMs: Int64 = 0
    
    for (round in 0..5) {
        let syncDir = "${testDir}/seq_sync_${round}"
        let ioUringDir = "${testDir}/seq_iouring_${round}"
        Directory.create(Path(syncDir), recursive: true)
        Directory.create(Path(ioUringDir), recursive: true)
        
        let t1 = MonoTime.now()
        for (i in 0..numFiles) {
            let f = File(Path("${syncDir}/${i}.sst"), Write)
            f.write(data)
            f.close()
        }
        let t2 = MonoTime.now()
        let thisSyncMs = (t2 - t1).toNanoseconds() / 1000000
        if (thisSyncMs > syncMs) { syncMs = thisSyncMs }
        
        let t3 = MonoTime.now()
        for (i in 0..numFiles) {
            writeFile("${ioUringDir}/${i}.sst", data, useIoUring: true)
        }
        let t4 = MonoTime.now()
        let thisIoUringMs = (t4 - t3).toNanoseconds() / 1000000
        if (thisIoUringMs > ioUringMs) { ioUringMs = thisIoUringMs }
        
        cleanupDir(syncDir)
        cleanupDir(ioUringDir)
    }
    
    (syncMs, ioUringMs, totalMB)
}

func generateSSTableData(targetSize: Int64): Array<Byte> {
    let builder = TableBuilder(blockSize: 4 * 1024, bloomFalsePositive: 0.01)
    
    let keyPrefix = "key_".toArray()
    let valPrefix = "value_".toArray()
    let keyBuf = Array<Byte>(32, repeat: 0)
    let valBuf = Array<Byte>(256, repeat: 0)
    
    var currentSize: Int64 = 0
    var keyIndex: Int64 = 0
    
    while (currentSize < targetSize) {
        let key = makeKey(keyPrefix, keyIndex, keyBuf)
        let value = makeValue(valPrefix, keyIndex, valBuf, 128)
        builder.add(key, value)
        
        currentSize += key.size + value.value.size
        keyIndex++
    }
    
    builder.finish()
}

func makeKey(prefix: Array<Byte>, n: Int64, buf: Array<Byte>): Array<Byte> {
    var pos = 0
    for (i in 0..prefix.size) {
        buf[pos] = prefix[i]
        pos++
    }
    pos = writeInt(buf, pos, n)
    let ts = UInt64(n)
    buf[pos] = UInt8(ts & 0xFFu64)
    buf[pos + 1] = UInt8((ts >> 8u64) & 0xFFu64)
    buf[pos + 2] = UInt8((ts >> 16u64) & 0xFFu64)
    buf[pos + 3] = UInt8((ts >> 24u64) & 0xFFu64)
    buf[pos + 4] = UInt8((ts >> 32u64) & 0xFFu64)
    buf[pos + 5] = UInt8((ts >> 40u64) & 0xFFu64)
    buf[pos + 6] = UInt8((ts >> 48u64) & 0xFFu64)
    buf[pos + 7] = UInt8((ts >> 56u64) & 0xFFu64)
    return buf[0..pos + 8]
}

func makeValue(prefix: Array<Byte>, n: Int64, buf: Array<Byte>, size: Int64): ValueStruct {
    var pos = 0
    for (i in 0..prefix.size) {
        buf[pos] = prefix[i]
        pos++
    }
    pos = writeInt(buf, pos, n)
    
    while (pos < size && pos < buf.size) {
        buf[pos] = UInt8((pos + n) % 256)
        pos++
    }
    
    ValueStruct(buf[0..pos], meta: 0, version: UInt64(n))
}

func writeInt(buf: Array<Byte>, pos: Int64, n: Int64): Int64 {
    if (n == 0) {
        buf[pos] = b'0'
        return pos + 1
    }
    var num = n
    var end = pos
    while (num > 0) {
        buf[end] = b'0' + UInt8(num % 10)
        num /= 10
        end++
    }
    let start = pos
    let len = end - start
    for (i in 0..len / 2) {
        let tmp = buf[start + i]
        buf[start + i] = buf[end - 1 - i]
        buf[end - 1 - i] = tmp
    }
    return end
}

func cleanupDir(path: String): Unit {
    if (exists(Path(path))) {
        remove(Path(path), recursive: true)
    }
}