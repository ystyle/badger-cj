package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*

/**
 * 常规 flush 的存储后端。
 *
 * v2.0「表数据移出 GC 堆」必须在**运行期单表 flush**（flusher → persistMemTable）与
 * close 兜底路径（flushMemTablesBatch）上都生效；此前只有批量路径接入了 MmapTableData，
 * 常规 flush 仍把整张 SSTable 留在 GC 堆——稳态内存目标实际上没有兑现。
 */
@Test
class FlushMmapBackingTest {
    @TestCase
    func testFlushMemTableUsesMmapBacking(): Unit {
        let dir = "/tmp/badger_flush_mmap_default"
        cleanupDir(dir)
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)

        db.updateOrThrow({ txn =>
            for (i in 0..50) {
                txn.set("key-${i}".toArray(), "value-${i}".toArray())
            }
        })
        db.flushMemTable()

        let kinds = db.getL0BackingKinds()
        @Assert(kinds.size >= 1, true)
        for (k in kinds) {
            @Assert(k == "mmap", true)
        }
        // 映射路径读回正确
        let v = db.view({ txn => txn.get("key-7".toArray()) })
        @Assert(v.isSome(), true)

        db.close()
        cleanupDir(dir)
    }

    @TestCase
    func testFlushMemTableMemoryBackingWhenDisabled(): Unit {
        let dir = "/tmp/badger_flush_mmap_disabled"
        cleanupDir(dir)
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64).withMmapSSTable(false)
        let db = Badger.open(opt)

        db.updateOrThrow({ txn =>
            for (i in 0..20) {
                txn.set("k-${i}".toArray(), "v-${i}".toArray())
            }
        })
        db.flushMemTable()

        let kinds = db.getL0BackingKinds()
        @Assert(kinds.size >= 1, true)
        for (k in kinds) {
            @Assert(k == "memory", true)
        }

        db.close()
        cleanupDir(dir)
    }
}
