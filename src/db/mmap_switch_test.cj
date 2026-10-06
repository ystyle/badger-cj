package badgercj.db

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

/**
 * v2.0 的 mmap 开关（Config.MmapWAL / Config.MmapVLog）行为回归：
 * 两个开关都能独立关闭回退到 v1.x 路径，关闭后数据读写语义不变。
 */
@Test
class MmapSwitchTest {
    private func cleanup(dir: String): Unit {
        let p = Path(dir)
        if (exists(p)) {
            remove(p, recursive: true)
        }
    }

    @TestCase
    func testBothMmapDisabledStillRoundTrips(): Unit {
        let dir = "./test_mmap_switch_off"
        cleanup(dir)
        // valueThreshold 调小，让小 value 也走 VLog，从而覆盖 MmapVLog 路径
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64,
            valueThreshold: 64u64, mmapWAL: false, mmapVLog: false)
        let db = Badger.open(opt)
        let bigValue = Array<Byte>(4096, repeat: 42u8)
        let r = db.update({ t =>
            t.set("k1".toArray(), "small".toArray())
            t.set("k2".toArray(), bigValue)
        })
        @Expect(r.isSuccess(), true)
        @Expect(db.get("k1".toArray()).getOrThrow().value, "small".toArray())
        @Expect(db.get("k2".toArray()).getOrThrow().value, bigValue)
        db.close()
        cleanup(dir)
    }

    @TestCase
    func testMmapVLogOnRotatesSegment(): Unit {
        let dir = "./test_mmap_switch_on"
        cleanup(dir)
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64,
            valueThreshold: 64u64, mmapWAL: true, mmapVLog: true)
        let db = Badger.open(opt)
        let bigValue = Array<Byte>(1024, repeat: 7u8)
        for (i in 0..64) {
            let _ = db.update({ t => t.set("key${i}".toArray(), bigValue) })
        }
        for (i in 0..64) {
            @Expect(db.get("key${i}".toArray()).getOrThrow().value, bigValue)
        }
        db.close()
        cleanup(dir)
    }

    @TestCase
    func testSSTableMmapDisabledStillRoundTrips(): Unit {
        // 关闭 SSTable 映射（整表读入 GC 堆）后，flush 落盘 → 重开 loadTables 两条路径语义不变。
        // 默认开启（映射）的路径由其余 387 个用例覆盖。
        let dir = "./test_mmap_switch_sst_off"
        cleanup(dir)
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64,
            valueThreshold: 64u64, mmapWAL: true, mmapVLog: true, mmapSSTable: false)
        let db = Badger.open(opt)
        let value = Array<Byte>(512, repeat: 5u8)
        // 写入量超过 memTableSize，触发 flush 落盘生成 .sst
        for (i in 0..300) {
            let _ = db.update({ t => t.set("mk${i}".toArray(), value) })
        }
        @Expect(db.get("mk299".toArray()).getOrThrow().value, value)
        db.close()

        // 重开：loadTables 走非映射路径读回全部
        let db2 = Badger.open(opt)
        @Expect(db2.get("mk0".toArray()).getOrThrow().value, value)
        @Expect(db2.get("mk299".toArray()).getOrThrow().value, value)
        db2.close()
        cleanup(dir)
    }
}
