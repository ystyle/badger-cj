package badgercj.examples.key_compare_perf

import std.time.*
import std.random.*
import std.collection.*
import badgercj.arena.*
import badgercj.skiplist.*

main(): Int64 {
    let shortKeyLen = 16
    let longKeyLen = 256
    let veryLongKeyLen = 1024
    let iterations = 1000000
    
    // 准备 Arena 和 AtomicStorage
    let arena = Arena(64 * 1024 * 1024)
    let atomicStorage = AtomicStorage(100000)
    let list = Skiplist(arena, atomicStorage)
    
    // 准备 key
    let rng = Random(42u64)
    var shortKeys = ArrayList<Array<Byte>>()
    var longKeys = ArrayList<Array<Byte>>()
    var veryLongKeys = ArrayList<Array<Byte>>()
    
    for (i in 0..1000) {
        shortKeys.add(randomKey(rng, shortKeyLen))
        longKeys.add(randomKey(rng, longKeyLen))
        veryLongKeys.add(randomKey(rng, veryLongKeyLen))
    }
    
    // 插入数据
    for (key in shortKeys) {
        list.add(key, 100u64)
    }
    for (key in longKeys) {
        list.add(key, 200u64)
    }
    for (key in veryLongKeys) {
        list.add(key, 300u64)
    }
    
    println("=== Key Compare Performance Test ===")
    println("Short key: ${shortKeyLen} bytes, Long key: ${longKeyLen} bytes, Very long key: ${veryLongKeyLen} bytes")
    println("Iterations: ${iterations}")
    println("")
    
    // 测试短 key 比较
    let start1 = MonoTime.now()
    var count1: UInt64 = 0
    for (_ in 0..iterations) {
        let idx = rng.nextUInt32() % 1000
        if (list.get(shortKeys[Int64(idx)]).isSome()) {
            count1++
        }
    }
    let elapsed1 = MonoTime.now() - start1
    
    println("Short key (${shortKeyLen} bytes):")
    println("  Time: ${elapsed1.toNanoseconds() / 1000000}ms")
    println("  Per op: ${elapsed1.toNanoseconds() / iterations}ns")
    println("  Ops/s: ${iterations * 1000000000 / elapsed1.toNanoseconds()}")
    println("")
    
    // 测试长 key 比较
    let start2 = MonoTime.now()
    var count2: UInt64 = 0
    for (_ in 0..iterations) {
        let idx = rng.nextUInt32() % 1000
        if (list.get(longKeys[Int64(idx)]).isSome()) {
            count2++
        }
    }
    let elapsed2 = MonoTime.now() - start2
    
    println("Long key (${longKeyLen} bytes):")
    println("  Time: ${elapsed2.toNanoseconds() / 1000000}ms")
    println("  Per op: ${elapsed2.toNanoseconds() / iterations}ns")
    println("  Ops/s: ${iterations * 1000000000 / elapsed2.toNanoseconds()}")
    println("")
    
    // 测试超长 key 比较
    let start3 = MonoTime.now()
    var count3: UInt64 = 0
    for (_ in 0..iterations) {
        let idx = rng.nextUInt32() % 1000
        if (list.get(veryLongKeys[Int64(idx)]).isSome()) {
            count3++
        }
    }
    let elapsed3 = MonoTime.now() - start3
    
    println("Very long key (${veryLongKeyLen} bytes):")
    println("  Time: ${elapsed3.toNanoseconds() / 1000000}ms")
    println("  Per op: ${elapsed3.toNanoseconds() / iterations}ns")
    println("  Ops/s: ${iterations * 1000000000 / elapsed3.toNanoseconds()}")
    println("")
    
    // 性能对比
    let ratio2 = Float64(elapsed2.toNanoseconds()) / Float64(elapsed1.toNanoseconds())
    let ratio3 = Float64(elapsed3.toNanoseconds()) / Float64(elapsed1.toNanoseconds())
    println("Long key is ${ratio2}x slower than short key")
    println("Very long key is ${ratio3}x slower than short key")
    
    0
}

func randomKey(rng: Random, len: Int64): Array<Byte> {
    let arr = Array<Byte>(len, { _ => UInt8(rng.nextUInt32() % 256) })
    return arr
}