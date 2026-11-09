package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.fs.*

/**
 * VLog GC 的选段依据：compaction 丢弃旧版本时，必须把旧值在 vlog 中占用的字节
 * 按 fid 累计到 discard stats（此前 addDiscard 全仓无调用者 → 丢弃率恒 0 →
 * pickLog 恒 None → runGC 每 60s 空转，大值段永不回收）。
 */
@Test
class VLogDiscardTest {
    @TestCase
    func testCompactionAccumulatesDiscardStats(): Unit {
        let dir = "/tmp/badger_vlog_discard_accum"
        cleanupDir(dir)
        let opt = Config(
            dir: dir,
            memTableSize: 64 * 1024u64,
            valueThreshold: 128u64,
            vlogFileSize: 64 * 1024u64,
            numLevelZeroTables: 1,
            disableWAL: true
        )
        let db = Badger.open(opt)

        let gen1 = vlogDiscardValue("gen1", 512)
        db.updateOrThrow({ txn =>
            for (i in 0..20) {
                txn.set("k-${i}".toArray(), gen1)
            }
        })
        db.flushMemTable()

        let gen2 = vlogDiscardValue("gen2", 512)
        db.updateOrThrow({ txn =>
            for (i in 0..20) {
                txn.set("k-${i}".toArray(), gen2)
            }
        })
        db.flushMemTable()

        compactWithFreshWatermark(db)
        @Assert(db.getVLogDiscardTotal() > 0, true)

        // 合并后读到的必须是新值（旧值指针被丢弃，但活值不能被误伤）
        for (i in 0..20) {
            match (db.get("k-${i}".toArray())) {
                case Some(vs) => @Assert(vs.value, gen2)
                case None => @Fail("k-${i} 在 compaction 后丢失")
            }
        }

        db.close()
        cleanupDir(dir)
    }

    @TestCase
    func testVLogFileSizeControlsSegments(): Unit {
        let dir = "/tmp/badger_vlog_segment_size"
        cleanupDir(dir)
        let opt = Config(
            dir: dir,
            memTableSize: 64 * 1024u64,
            valueThreshold: 64u64,
            vlogFileSize: 8 * 1024u64,
            disableWAL: true
        )
        let db = Badger.open(opt)

        let value = vlogDiscardValue("seg", 512)
        db.updateOrThrow({ txn =>
            for (i in 0..40) {
                txn.set("s-${i}".toArray(), value)
            }
        })
        db.flushMemTable()

        var segments: Int64 = 0
        for (e in Directory.readFrom(Path(dir))) {
            if (e.name.endsWith(".vlog")) {
                segments++
            }
        }
        // 40 × ~525B ≈ 21KB，段容量 8KB → 至少 3 段
        @Assert(segments >= 3, true)

        for (i in 0..40) {
            match (db.get("s-${i}".toArray())) {
                case Some(vs) => @Assert(vs.value, value)
                case None => @Fail("s-${i} 丢失")
            }
        }

        db.close()
        cleanupDir(dir)
    }
}

func vlogDiscardValue(tag: String, size: Int64): Array<Byte> {
    let buf = Array<Byte>(size, repeat: 0x5A)
    let tagBytes = tag.toArray()
    let n = if (tagBytes.size < buf.size) { tagBytes.size } else { buf.size }
    tagBytes.copyTo(buf, 0, 0, n)
    buf
}

// 先推进 read watermark 再触发一轮「L0 + 重叠 L1」压缩：
// 保留策略按 discardTs（活跃读者最小 readTs）决定丢弃，若不推进水位，
// 最新版本 > discardTs 会连同其上一版一起保留，compaction 不产生垃圾。
func compactWithFreshWatermark(db: Badger): Unit {
    let txn = db.newTransaction(update: false)
    txn.discard()
    db.updateOrThrow({ txn2 => txn2.set("__compact_trigger".toArray(), "1".toArray()) })
    db.flushMemTable()
    db.compact()
}
