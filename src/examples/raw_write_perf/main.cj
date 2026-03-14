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
    let opt = Config(dir: dir, memTableSize: 256 * 1024 * 1024, disableWAL: false)
    let mt = MemTable(opt, 1, false)
    
    let startTime = MonoTime.now()
    
    let keyPrefix = "key_".toArray()
    let valPrefix = "value_".toArray()
    let keyBuf = Array<Byte>(32, repeat: 0)
    let valBuf = Array<Byte>(32, repeat: 0)
    
    for (i in 0..totalWrites) {
        let key = makeKey(keyPrefix, i, keyBuf)
        let value = makeValue(valPrefix, i, valBuf)
        mt.put(key, value)
    }
    
    let elapsed = MonoTime.now() - startTime
    let ns = elapsed.toNanoseconds()
    let ms = ns / 1000000
    let keysPerSec = totalWrites * 1000000000 / ns
    
    println("DIRECT: ${formatNum(totalWrites)} keys in ${ms}ms, ${formatNum(keysPerSec)} keys/s")
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

func makeValue(prefix: Array<Byte>, n: Int64, buf: Array<Byte>): ValueStruct {
    var pos = 0
    for (i in 0..prefix.size) {
        buf[pos] = prefix[i]
        pos++
    }
    pos = writeInt(buf, pos, n)
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