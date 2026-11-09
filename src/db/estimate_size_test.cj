package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*

// EstimateSize：只统计左右边界都命中前缀的 SSTable；空 prefix = 全部（对齐 go EstimateSize）。
@Test
class EstimateSizeTest {
    @TestCase
    func testEstimateSizeByPrefix(): Unit {
        let dir = "/tmp/badger_estimate_size"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64, disableWAL: true))

        db.updateOrThrow({ txn =>
            for (i in 0..50) {
                txn.set("a/${i}".toArray(), Array<Byte>(300, repeat: 0x61))
            }
        })
        db.flushMemTable()
        db.updateOrThrow({ txn =>
            for (i in 0..50) {
                txn.set("b/${i}".toArray(), Array<Byte>(300, repeat: 0x62))
            }
        })
        db.flushMemTable()

        let (aDisk, aRaw) = db.estimateSize("a/".toArray())
        @Assert(aDisk > 0, true)
        @Assert(aRaw > 0, true)

        let (cDisk, cRaw) = db.estimateSize("c/".toArray())
        @Assert(cDisk, 0)
        @Assert(cRaw, 0)

        let (allDisk, _) = db.estimateSize([])
        @Assert(allDisk > aDisk, true)

        // 未落盘的 memtable 不计入（与 go 一致）
        db.updateOrThrow({ txn => txn.set("z/1".toArray(), Array<Byte>(300, repeat: 0x7A)) })
        let (zDisk, _) = db.estimateSize("z/".toArray())
        @Assert(zDisk, 0)

        db.close()
        cleanupDir(dir)
    }
}
