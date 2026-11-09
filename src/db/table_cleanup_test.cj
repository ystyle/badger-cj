package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*

// 表文件生命周期回归：compaction 摘表后必须回收 .sst；open 时必须清理孤儿 .sst。
//
// 缺陷形态（≤ 2.0.0）：compaction 的 deleteTables 只做「摘表 + close 映射」，
// 全仓没有任何删除表文件的调用 —— 被合并掉的旧表永久留在目录里，磁盘随每轮
// compaction 单调增长（长期运行的服务/容器备份会持续膨胀）。同时崩溃窗口里
// 「已建表但 MANIFEST 未记录」的文件也无人清理。
// 修复：① 摘表后先 close 再 unlink（Windows 约定）；② 打开时按 manifest 清理孤儿。
@Test
class TableCleanupTest {
    // 等宽 key：避免 user key 互为前缀（keyWithTs 原始字节比较下的既有编码限制）
    private func tcKey(i: Int64): Array<Byte> {
        let raw = i.toString()
        let pad = 4 - raw.size
        ("tc-" + String.fromUtf8(Array<Byte>(pad, repeat: 0x30)) + raw).toArray()
    }

    @TestCase
    func testCompactionRemovesObsoleteTableFiles(): Unit {
        let dir = "/tmp/badger_table_cleanup"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64, numLevelZeroTables: 1))
        let value = Array<Byte>(200, repeat: 0x5A)
        var written: Int64 = 0
        while (written < 400) {
            let start = written
            db.updateOrThrow({ txn =>
                var i = start
                while (i < start + 50 && i < 400) {
                    txn.set(tcKey(i), value)
                    i++
                }
            })
            written += 50
        }
        db.flushMemTable()
        db.compact()
        db.flushMemTable()
        db.compact()
        db.close()

        // 压缩（含后台压缩）结束后，磁盘上只剩 manifest 活表对应的 .sst
        let db2 = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64, numLevelZeroTables: 1))
        let infos = db2.tables()
        let sstFiles = testCountFilesWithSuffix(dir, ".sst")
        println("[table-cleanup] liveTables=" + infos.size.toString() + " sstFiles=" + sstFiles.toString())
        @Assert(sstFiles, Int64(infos.size))
        for (t in infos) {
            @Assert(exists(Path(sstablePath(dir, t.ID))), true)
        }
        // 数据完整
        for (i in 0..400) {
            @Assert(db2.get(tcKey(i)).isSome(), true)
        }
        db2.close()
        cleanupDir(dir)
    }

    @TestCase
    func testOrphanTableFileRemovedOnOpen(): Unit {
        let dir = "/tmp/badger_table_orphan"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))
        db.updateOrThrow({ txn => txn.set("orphan-key".toArray(), Array<Byte>(10, repeat: 1)) })
        db.flushMemTable()
        db.close()

        // 造一个「已建表但 manifest 从未记录」的孤儿文件（崩溃窗口的形态）
        let orphan = dir + "/999999.sst"
        let f = File(Path(orphan), ReadWrite)
        f.write(Array<Byte>(64, repeat: 0x7F))
        f.close()
        @Assert(exists(Path(orphan)), true)

        let db2 = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))
        @Assert(exists(Path(orphan)), false)
        @Assert(db2.get("orphan-key".toArray()).isSome(), true)
        db2.close()
        cleanupDir(dir)
    }
}
