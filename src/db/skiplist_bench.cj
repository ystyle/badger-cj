package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.random.*
import badgercj.arena.*
import badgercj.skiplist.*

func benchPadNum(n: Int64, digits: Int64): String {
    let s = n.toString()
    if (s.size >= digits) {
        return s
    }
    return "0" * (digits - s.size) + s
}

func benchRandomKey(rng: Random): Array<Byte> {
    let key = rng.nextInt64(100000000)
    return "k${benchPadNum(key, 16)}".toArray()
}

@Test
class SkiplistBench {
    
    @Bench
    func benchPut() {
        let arena = Arena(64 * 1024 * 1024)
        let list = Skiplist(arena)
        let rng = Random(42)
        
        for (_ in 0..1000) {
            let key = benchRandomKey(rng)
            list.add(key, 100u64)
        }
    }
    
    @Bench
    func benchGet() {
        let arena = Arena(64 * 1024 * 1024)
        let list = Skiplist(arena)
        let rng = Random(42)
        
        for (_ in 0..1000) {
            let key = benchRandomKey(rng)
            list.add(key, 100u64)
        }
        
        let rng2 = Random(42)
        for (_ in 0..1000) {
            let key = benchRandomKey(rng2)
            list.get(key)
        }
    }
}
