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
}
