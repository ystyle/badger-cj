/**
 * SkiplistBench - 与 Go 版本对齐的基准测试
 */
package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.random.*
import std.sync.*
import std.collection.*
import badgercj.arena.*
import badgercj.skiplist.*

func benchRandomKey(rng: Random): Array<Byte> {
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

@Test
class SkiplistBench {
    private var arena: Arena = Arena(64 * 1024 * 1024)
    private var atomicStorage: AtomicStorage = AtomicStorage(100000)
    private var list: Skiplist = Skiplist(arena, atomicStorage)
    private var key: Array<Byte> = []
    private var result: UInt64 = 0
    
    public init() {}
    
    @BeforeAll
    func setup() {
        arena = Arena(64 * 1024 * 1024)
        atomicStorage = AtomicStorage(100000)
        list = Skiplist(arena, atomicStorage)
        
        let rng = Random(42u64)
        for (_ in 0..1000) {
            let k = benchRandomKey(rng)
            list.add(k, 100u64)
        }
        
        key = benchRandomKey(Random(123u64))
        list.add(key, 200u64)
    }
    
    @Bench
    func benchPut() {
        list.add(key, 100u64)
    }
    
    @Bench
    func benchGet() {
        if (let Some(node) <- list.get(key)) {
            result = node.getValue()
        }
    }
}
