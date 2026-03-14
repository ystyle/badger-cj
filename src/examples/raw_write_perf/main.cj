package badgercj.examples.raw_write_perf

import std.fs.*
import std.time.*
import std.collection.*
import badgercj.db.*
import badgercj.table.*
import badgercj.skiplist.*
import std.sync.*
import std.random.Random

main(): Int64 {
    let dir = "/tmp/badger_raw_write_perf"
    cleanupDir(dir)
    
    runDirectWrite(dir, 500000)
    
    cleanupDir(dir)
    return 0
} 

func runDirectWrite(dir: String, totalWrites: Int64): Unit {
    let opt = Config(dir: dir, memTableSize: 256 * 1024 * 1024, disableWAL: true)
    let mt = MemTable(opt, 1, false)
    
    let startTime = MonoTime.now()
    
    let rng = Random(12345u64)
    for (i in 0..totalWrites) {
        let key = keyWithTs("key_${i}".toArray(), UInt64(i))
        let value = ValueStruct("value_${i}".toArray(), meta: 0, version: UInt64(i))
        mt.put(key, value)
    }
    
    let elapsed = MonoTime.now() - startTime
    let ns = elapsed.toNanoseconds()
    let ms = ns / 1000000
    let keysPerSec = totalWrites * 1000000000 / ns
    
    println("DIRECT: ${formatNum(totalWrites)} keys in ${ms}ms, ${formatNum(keysPerSec)} keys/s")
}

func keyWithTs(key: Array<Byte>, ts: UInt64): Array<Byte> {
    let result = Array<Byte>(key.size + 8, repeat: 0)
    for (i in 0..key.size) {
        result[i] = key[i]
    }
    let offset = key.size
    result[offset] = UInt8(ts & 0xFFu64)
    result[offset + 1] = UInt8((ts >> 8u64) & 0xFFu64)
    result[offset + 2] = UInt8((ts >> 16u64) & 0xFFu64)
    result[offset + 3] = UInt8((ts >> 24u64) & 0xFFu64)
    result[offset + 4] = UInt8((ts >> 32u64) & 0xFFu64)
    result[offset + 5] = UInt8((ts >> 40u64) & 0xFFu64)
    result[offset + 6] = UInt8((ts >> 48u64) & 0xFFu64)
    result[offset + 7] = UInt8((ts >> 56u64) & 0xFFu64)
    return result
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