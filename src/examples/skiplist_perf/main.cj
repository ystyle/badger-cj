package badgercj.examples.skiplist_perf

import std.random.*
import std.time.*
import std.sync.*
import std.collection.*
import badgercj.arena.*
import badgercj.skiplist.*

func randomKey(rng: Random): Array<Byte> {
    let key = rng.nextUInt32()
    let key2 = rng.nextUInt32()
    let arr = Array<Byte>(8, repeat: 0)
    arr[0] = UInt8(key & 0xFF)
    arr[1] = UInt8((key >> 8) & 0xFF)
    arr[2] = UInt8((key >> 16) & 0xFF)
    arr[3] = UInt8((key >> 24) & 0xFF)
    arr[4] = UInt8(key2 & 0xFF)
    arr[5] = UInt8((key2 >> 8) & 0xFF)
    arr[6] = UInt8((key2 >> 16) & 0xFF)
    arr[7] = UInt8((key2 >> 24) & 0xFF)
    return arr
}

main() {
    let n = 5000
    let numThreads = 16
    let perThread = n / numThreads
    
    println("=== Skiplist Performance Test ===")
    println("Operations: ${n}, Threads: ${numThreads}")
    
    // 1. Concurrent Write
    let arena = Arena(32 * 1024 * 1024)
    let atomicStorage = AtomicStorage(Int64(n + 1000))
    let list = Skiplist(arena, atomicStorage)
    
    println("\n--- Concurrent Write ---")
    let startWrite = MonoTime.now()
    let futures = ArrayList<Future<Unit>>()
    
    for (t in 0..numThreads) {
        let seed = UInt64((t + 1) * 1000)
        let fut = spawn {
            let rng = Random(seed)
            for (_ in 0..perThread) {
                let key = randomKey(rng)
                list.add(key, 100u64)
            }
        }
        futures.add(fut)
    }
    
    for (f in futures) {
        f.get()
    }
    
    let writeTime = MonoTime.now() - startWrite
    let writeNs = writeTime.toNanoseconds()
    println("Total time: ${writeNs / 1000000} ms")
    println("Per op: ${writeNs / n} ns/op")
    println("Throughput: ${n * 1000000000 / writeNs} ops/sec")
    
    // 2. Concurrent Read (先写入数据)
    let arena2 = Arena(256 * 1024 * 1024)
    let atomicStorage2 = AtomicStorage(Int64(n + 1000))
    let list2 = Skiplist(arena2, atomicStorage2)
    
    let rngSetup = Random(42u64)
    let keys = ArrayList<Array<Byte>>()
    for (_ in 0..n) {
        let key = randomKey(rngSetup)
        keys.add(key)
        list2.add(key, 100u64)
    }
    
    println("\n--- Concurrent Read ---")
    let startRead = MonoTime.now()
    let futures2 = ArrayList<Future<Unit>>()
    
    for (t in 0..numThreads) {
        let startIdx = t * perThread
        let fut = spawn {
            for (i in startIdx..(startIdx + perThread)) {
                let _ = list2.get(keys[i])
            }
        }
        futures2.add(fut)
    }
    
    for (f in futures2) {
        f.get()
    }
    
    let readTime = MonoTime.now() - startRead
    let readNs = readTime.toNanoseconds()
    println("Total time: ${readNs / 1000000} ms")
    println("Per op: ${readNs / n} ns/op")
    println("Throughput: ${n * 1000000000 / readNs} ops/sec")
    
    // 3. Sequential Write
    let arena3 = Arena(256 * 1024 * 1024)
    let atomicStorage3 = AtomicStorage(Int64(n + 1000))
    let list3 = Skiplist(arena3, atomicStorage3)
    
    println("\n--- Sequential Write ---")
    let startSeqWrite = MonoTime.now()
    let rngSeq = Random(42u64)
    for (_ in 0..n) {
        let key = randomKey(rngSeq)
        list3.add(key, 100u64)
    }
    let seqWriteTime = MonoTime.now() - startSeqWrite
    let seqWriteNs = seqWriteTime.toNanoseconds()
    println("Total time: ${seqWriteNs / 1000000} ms")
    println("Per op: ${seqWriteNs / n} ns/op")
    println("Throughput: ${n * 1000000000 / seqWriteNs} ops/sec")
    
    // 4. Sequential Read
    let arena4 = Arena(256 * 1024 * 1024)
    let atomicStorage4 = AtomicStorage(Int64(n + 1000))
    let list4 = Skiplist(arena4, atomicStorage4)
    
    let rngSeqRead = Random(42u64)
    let keys2 = ArrayList<Array<Byte>>()
    for (_ in 0..n) {
        let key = randomKey(rngSeqRead)
        keys2.add(key)
        list4.add(key, 100u64)
    }
    
    println("\n--- Sequential Read ---")
    let startSeqRead = MonoTime.now()
    let rngSeqRead2 = Random(42u64)
    for (_ in 0..n) {
        let key = randomKey(rngSeqRead2)
        let _ = list4.get(key)
    }
    let seqReadTime = MonoTime.now() - startSeqRead
    let seqReadNs = seqReadTime.toNanoseconds()
    println("Total time: ${seqReadNs / 1000000} ms")
    println("Per op: ${seqReadNs / n} ns/op")
    println("Throughput: ${n * 1000000000 / seqReadNs} ops/sec")
    
    println("\n=== Test Complete ===")
    return 0
}
