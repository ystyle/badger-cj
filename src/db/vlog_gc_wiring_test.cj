package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.fs.*

/**
 * VLog GC 端到端：compaction 产生的垃圾统计 → runVLogGC 选段 → 重写活值 →
 * 旧段延迟删除（活跃迭代器归零后才删；Windows 先 close 再 unlink）。
 */
@Test
class VLogGcWiringTest {
    @TestCase
    func testRunVLogGCReclaimsDeadSegmentAndKeepsLiveValues(): Unit {
        let dir = "/tmp/badger_vlog_gc_e2e"
        cleanupDir(dir)
        let opt = Config(
            dir: dir,
            memTableSize: 64 * 1024u64,
            valueThreshold: 64u64,
            vlogFileSize: 8 * 1024u64,
            numLevelZeroTables: 1,
            disableWAL: true
        )
        let db = Badger.open(opt)

        let gen1 = vlogGcValue("gen1", 512)
        db.updateOrThrow({ txn =>
            for (i in 0..60) {
                txn.set("k-${i}".toArray(), gen1)
            }
        })
        db.flushMemTable()

        let gen2 = vlogGcValue("gen2", 512)
        db.updateOrThrow({ txn =>
            for (i in 0..30) {
                txn.set("k-${i}".toArray(), gen2)
            }
            for (i in 50..60) {
                txn.delete("k-${i}".toArray())
            }
        })
        db.flushMemTable()

        compactWithFreshWatermark(db)
        @Assert(db.getVLogDiscardTotal() > 0, true)

        let before = vlogGcSegments(dir)
        @Assert(before.size >= 3, true)

        // 持有迭代器：GC 重写后的旧段必须延迟删除（迭代器可能持有旧值指针）
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator()
        iter.rewind()

        var ran = false
        for (_ in 0..5) {
            if (db.runVLogGC(0.05)) {
                ran = true
                break
            }
        }
        @Assert(ran, true)
        @Assert(vlogGcSegments(dir).size == before.size, true)

        iter.close()
        txn.discard()

        let after = vlogGcSegments(dir)
        @Assert(after.size < before.size, true)

        for (i in 0..30) {
            match (db.get("k-${i}".toArray())) {
                case Some(vs) => @Assert(vs.value, gen2)
                case None => @Fail("k-${i} 在 GC 后丢失")
            }
        }
        for (i in 30..50) {
            match (db.get("k-${i}".toArray())) {
                case Some(vs) => @Assert(vs.value, gen1)
                case None => @Fail("k-${i} 在 GC 后丢失")
            }
        }
        for (i in 50..60) {
            @Assert(db.get("k-${i}".toArray()).isNone(), true)
        }

        db.close()
        cleanupDir(dir)
    }
}

func vlogGcValue(tag: String, size: Int64): Array<Byte> {
    let buf = Array<Byte>(size, repeat: 0x33)
    let tagBytes = tag.toArray()
    let n = if (tagBytes.size < buf.size) { tagBytes.size } else { buf.size }
    tagBytes.copyTo(buf, 0, 0, n)
    buf
}

func vlogGcSegments(dir: String): ArrayList<String> {
    let out = ArrayList<String>()
    for (e in Directory.readFrom(Path(dir))) {
        // 目录是快照、stat 是实时：列出条目后文件可能已被并发删除（GC / 换段），
        // 此时 isDirectory() 报 ENOENT（"Native function error return -1"）。
        // 统计口径只关心「此刻还在的段」，消失的条目跳过即可。
        try {
            if (!e.isDirectory() && e.name.endsWith(".vlog")) {
                out.add(e.name)
            }
        } catch (err: Exception) {
            // 条目在遍历期间被删除：忽略
        }
    }
    out
}

