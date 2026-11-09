package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.fs.*

// 迭代器跨 compaction 读取回归：被换下的表在迭代器读完之前不得解映射。
//
// 缺陷形态（≤ 2.1.0）：compaction 摘表即解映射并删文件，而已经建立的迭代器还要读
// 它剩余的块 —— 下一次进块抛 `MmapFile is closed`。现场表现：范围扫描 / 多级索引
// 链式遍历在 compaction 并发时整条读失败（偶发，取决于压缩时机）。
// 修复：表按引用释放（迭代器持有），归零才解映射/删文件。
@Test
class TableLifetimeTest {
    // 等宽 key：避免 user key 互为前缀（keyWithTs 原始字节比较下的既有编码限制）
    private func lk(i: Int64): Array<Byte> {
        let raw = i.toString()
        let pad = 4 - raw.size
        ("tl-" + String.fromUtf8(Array<Byte>(pad, repeat: 0x30)) + raw).toArray()
    }

    private func writeRange(db: Badger, count: Int64, value: Array<Byte>): Unit {
        db.updateOrThrow({ txn =>
            var i: Int64 = 0
            while (i < count) {
                txn.set(lk(i), value)
                i++
            }
        })
    }

    @TestCase
    func testIteratorSurvivesCompactionOfItsTables(): Unit {
        let dir = "/tmp/badger_table_lifetime"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 16 * 1024u64, numLevelZeroTables: 1))
        let oldValue = Array<Byte>(200, repeat: 0x11)
        let newValue = Array<Byte>(200, repeat: 0x22)
        let count: Int64 = 200

        // 第一批：落盘成表（供迭代器持有）
        writeRange(db, count, oldValue)
        db.flushMemTable()
        db.compact()
        let before = db.tables()
        @Assert(before.size > 0, true)
        let oldIds = ArrayList<UInt64>()
        for (t in before) {
            oldIds.add(t.ID)
        }

        // 建立快照迭代器：持有上述所有表的引用
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator()
        iter.rewind()
        var seen: Int64 = 0
        while (iter.valid()) {
            seen++
            iter.next()
        }
        @Assert(seen, count)

        // 第二批：覆写同一批 key 并压缩 —— 上一批表被换下、标记待删
        writeRange(db, count, newValue)
        db.flushMemTable()
        db.compact()

        // 确认本轮压缩确实换掉了迭代器持有的表（否则本用例没打到缺陷路径）
        let remain = HashSet<UInt64>()
        for (t in db.tables()) {
            remain.add(t.ID)
        }
        var replaced: Int64 = 0
        for (id in oldIds) {
            if (!remain.contains(id)) {
                replaced++
            }
        }
        @Assert(replaced, oldIds.size)

        // 旧迭代器继续读：仍是快照时刻的旧值，且不抛 MmapFile is closed
        iter.rewind()
        var n: Int64 = 0
        while (iter.valid()) {
            @Assert(iter.item().value, oldValue)
            n++
            iter.next()
        }
        @Assert(n, count)

        iter.close()
        txn.discard()
        // 表引用全部归还后，被换下的表文件应当已回收
        let sstFiles = testCountFilesWithSuffix(dir, ".sst")
        @Assert(sstFiles, Int64(db.tables().size))
        db.close()
        cleanupDir(dir)
    }
}
