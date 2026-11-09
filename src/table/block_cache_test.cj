package badgercj.table

import std.unittest.*
import std.unittest.testmacro.*

// BlockCache 单测：命中计数、LRU 淘汰、按表失效。
@Test
class BlockCacheTest {
    private func bytes(n: Int64): Array<Byte> {
        Array<Byte>(n, repeat: 0x7A)
    }

    @TestCase
    func testHitMissAndCapacity(): Unit {
        let cache = BlockCache(capacityBytes: 100)
        @Assert(cache.get(1, 0).isNone(), true)
        @Assert(cache.misses(), 1)
        cache.put(1, 0, bytes(40))
        @Assert(cache.get(1, 0).isSome(), true)
        @Assert(cache.hits(), 1)
        @Assert(cache.used(), 40)
        // 第二条放不下 100 字节 -> 最旧的被淘汰
        cache.put(1, 1, bytes(80))
        @Assert(cache.used(), 80)
        @Assert(cache.get(1, 0).isNone(), true)
        @Assert(cache.get(1, 1).isSome(), true)
        cache.clear()
        @Assert(cache.used(), 0)
    }

    @TestCase
    func testLruOrder(): Unit {
        let cache = BlockCache(capacityBytes: 120)
        cache.put(1, 0, bytes(40))
        cache.put(1, 1, bytes(40))
        cache.put(1, 2, bytes(40))
        // 访问 0 使其变热，再插入一条应淘汰 1（最久未用）
        let _ = cache.get(1, 0)
        cache.put(1, 3, bytes(40))
        @Assert(cache.get(1, 1).isNone(), true)
        @Assert(cache.get(1, 0).isSome(), true)
        @Assert(cache.get(1, 2).isSome(), true)
        @Assert(cache.get(1, 3).isSome(), true)
    }

    @TestCase
    func testInvalidateTableDropsOnlyThatTable(): Unit {
        let cache = BlockCache(capacityBytes: 1000)
        cache.put(1, 0, bytes(50))
        cache.put(1, 1, bytes(50))
        cache.put(2, 0, bytes(50))
        cache.invalidateTable(1)
        @Assert(cache.used(), 50)
        @Assert(cache.get(1, 0).isNone(), true)
        @Assert(cache.get(2, 0).isSome(), true)
    }

    @TestCase
    func testZeroCapacityNeverCaches(): Unit {
        let cache = BlockCache(capacityBytes: 0)
        cache.put(1, 0, bytes(10))
        @Assert(cache.used(), 0)
        @Assert(cache.get(1, 0).isNone(), true)
    }
}
