package badgercj.table

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*

// 阶段 6.1 lazy index：索引只保留「原始字节 + 4B/块位置表」，块 key 按需解析。
// 500 块的表：堆占用必须显著低于「每块一个对象 + 每块一份 key 副本」的旧模型，
// 同时查找/迭代结果与旧实现完全一致。
@Test
class LazyIndexTest {
    @TestCase
    func testIndexServesManyBlocksWithCompactHeap(): Unit {
        let builder = TableBuilder(blockSize: 256)
        let keys = ArrayList<Array<Byte>>()
        let values = ArrayList<Array<Byte>>()
        for (i in 0..500) {
            let key = fixedKey(i)
            let value = Array<Byte>(50, repeat: UInt8(i % 256))
            keys.add(key)
            values.add(value)
            builder.add(key, ValueStruct(value))
        }
        let data = builder.finish()
        let table = Table(1, data)

        let blocks = table.numBlocks()
        @Assert(blocks > 5, true)
        // 旧模型每块约 40B 对象头 + key 副本（8B）；新模型 = raw 共享 + 4B/块。
        // 这里用宽松上界 64B/块钉住「没有退回每块独立对象」。
        @Assert(table.indexHeapBytes() < blocks * 64, true)
        @Assert(table.indexHeapBytes() < table.dataSize(), true)

        for (i in 0..500) {
            match (table.get(keys[i])) {
                case Some(v) => @Assert(v, values[i])
                case None => @Fail("key ${i} 在索引中丢失")
            }
        }

        // 块定位单调；不存在的 key 返回 None
        var lastBlock: Int64 = -1
        for (i in 0..500) {
            let b = table.findBlock(keys[i])
            @Assert(b >= lastBlock, true)
            @Assert(b >= 0 && b < blocks, true)
            lastBlock = b
        }
        @Assert(table.get("zzz".toArray()).isNone(), true)

        // 逐块迭代仍能覆盖全部条目
        var seen: Int64 = 0
        for (b in 0..blocks) {
            let iter = table.blockIterator(b)
            iter.seekToFirst()
            while (iter.isValid()) {
                seen++
                iter.next()
            }
        }
        @Assert(seen, 500)
    }
}

func fixedKey(i: Int64): Array<Byte> {
    Array<Byte>(8, {j =>
        if (j < 4) {
            0u8
        } else {
            UInt8((i >> UInt64((3 - (j - 4)) * 8)) & 0xFF)
        }
    })
}
