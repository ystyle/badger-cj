package badgercj.examples.key_compare_perf

import std.time.*
import std.random.*
import std.collection.*
import std.sync.*
import badgercj.skiplist.*
import std.binary.*

// 全局变量防止编译器优化
let g_result: AtomicInt64 = AtomicInt64(0)

main(): Int64 {
    let iterations = 1000000
    let keyCount = 1000
    
    // 准备不同大小的 key
    let shortKeyLen = 16
    let longKeyLen = 64
    let veryLongKeyLen = 256
    let superLongKeyLen = 1024
    
    // 生成两组不同的随机 key
    let rng1 = Random(42u64)
    let rng2 = Random(123u64)
    
    var shortKeysA = ArrayList<Array<Byte>>()
    var longKeysA = ArrayList<Array<Byte>>()
    var veryLongKeysA = ArrayList<Array<Byte>>()
    var superLongKeysA = ArrayList<Array<Byte>>()
    
    var shortKeysB = ArrayList<Array<Byte>>()
    var longKeysB = ArrayList<Array<Byte>>()
    var veryLongKeysB = ArrayList<Array<Byte>>()
    var superLongKeysB = ArrayList<Array<Byte>>()
    
    for (i in 0..keyCount) {
        shortKeysA.add(randomKey(rng1, shortKeyLen))
        longKeysA.add(randomKey(rng1, longKeyLen))
        veryLongKeysA.add(randomKey(rng1, veryLongKeyLen))
        superLongKeysA.add(randomKey(rng1, superLongKeyLen))
        
        shortKeysB.add(randomKey(rng2, shortKeyLen))
        longKeysB.add(randomKey(rng2, longKeyLen))
        veryLongKeysB.add(randomKey(rng2, veryLongKeyLen))
        superLongKeysB.add(randomKey(rng2, superLongKeyLen))
    }
    
    println("=== Byte Array Compare Performance Test ===")
    println("Iterations: ${iterations}")
    println("比较两组不同的随机数组")
    println("")
    
    // 测试 16 字节
    testCompare("16 bytes", shortKeysA, shortKeysB, iterations)
    println("")
    
    // 测试 64 字节
    testCompare("64 bytes", longKeysA, longKeysB, iterations)
    println("")
    
    // 测试 256 字节
    testCompare("256 bytes", veryLongKeysA, veryLongKeysB, iterations)
    println("")
    
    // 测试 1024 字节
    testCompare("1024 bytes", superLongKeysA, superLongKeysB, iterations)
    
    println("")
    println("Final result: ${g_result.load()}")
    
    0
}

func testCompare(name: String, keysA: ArrayList<Array<Byte>>, keysB: ArrayList<Array<Byte>>, iterations: Int64): Unit {
    let keyCount = keysA.size
    
    // 逐字节比较 - 用两组不同的 key
    let start1 = MonoTime.now()
    for (i in 0..iterations) {
        let idx = i % keyCount
        let r = compareByteByByte(keysA[idx], keysB[idx])
        g_result.fetchAdd(r)
    }
    let elapsed1 = MonoTime.now() - start1
    
    // FFI memcmp - 用两组不同的 key
    let start2 = MonoTime.now()
    for (i in 0..iterations) {
        let idx = i % keyCount
        let keyA = keysA[idx]
        let keyB = keysB[idx]
        let len = if (keyA.size < keyB.size) { keyA.size } else { keyB.size }
        let r = Int64(fastMemcmp(keyA, 0, keyB, 0, len))
        g_result.fetchAdd(r)
    }
    let elapsed2 = MonoTime.now() - start2
    
    let ns1 = elapsed1.toNanoseconds() / iterations
    let ns2 = elapsed2.toNanoseconds() / iterations
    
    println("${name}:")
    println("  逐字节: ${ns1}ns/op")
    println("  FFI memcmp: ${ns2}ns/op")
    if (ns1 > ns2) {
        println("  FFI 快 ${Float64(ns1) / Float64(ns2)}x")
    } else {
        println("  逐字节快 ${Float64(ns2) / Float64(ns1)}x")
    }
}

func compareByteByByte(a: Array<Byte>, b: Array<Byte>): Int64 {
    let minLen = if (a.size < b.size) { a.size } else { b.size }
    
    for (i in 0..minLen) {
        if (a[i] < b[i]) {
            return -1
        } else if (a[i] > b[i]) {
            return 1
        }
    }
    
    return Int64(a.size - b.size)
}

func randomKey(rng: Random, len: Int64): Array<Byte> {
    Array<Byte>(len, { _ => UInt8(rng.nextUInt32() % 256) })
}