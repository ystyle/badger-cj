package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList

// DB 层大值（>= ValueThreshold）跨重开读回正确性：
// vlog 重开若不恢复段表与写偏移，重开后新写入条目的 ValuePointer.offset 会指回段首，
// get 侧不校验 key → 静默读到别的 key 的 value。这里从 DB 层钉住端到端语义。

func vlogReopenDbValue(tag: String, size: Int64): Array<Byte> {
    let buf = Array<Byte>(size, repeat: 0x42)
    let tagBytes = tag.toArray()
    let n = if (tagBytes.size < buf.size) {
        tagBytes.size
    } else {
        buf.size
    }
    tagBytes.copyTo(buf, 0, 0, n)
    buf
}

@Test
class VLogReopenPersistTest {
    // 写若干大值 → close → reopen 逐 key 读回全对 → 再写新大值 → 再 reopen 仍全对。
    @TestCase
    func testLargeValuesSurviveReopen() {
        let dir = "/tmp/badger_vlog_reopen_persist"
        cleanupDir(dir)
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64, valueThreshold: 1024u64)

        let expected = ArrayList<Array<Byte>>()
        let db1 = Badger.open(opt)
        db1.updateOrThrow({ txn =>
            for (i in 0..10) {
                let v = vlogReopenDbValue("gen1-${i}-", 4096)
                expected.add(v)
                txn.set("big-${i}".toArray(), v)
            }
        })
        db1.close()

        let db2 = Badger.open(opt)
        for (i in 0..10) {
            match (db2.get("big-${i}".toArray())) {
                case Some(vs) => @Assert(vs.value, expected[i])
                case None => @Fail("big-${i} 重开后缺失")
            }
        }

        // 重开之后继续写新大值：写偏移必须接在已有数据之后，且写后立即读回自己的值
        db2.updateOrThrow({ txn =>
            for (i in 10..15) {
                let v = vlogReopenDbValue("gen2-${i}-", 4096)
                expected.add(v)
                txn.set("big-${i}".toArray(), v)
            }
        })
        for (i in 10..15) {
            match (db2.get("big-${i}".toArray())) {
                case Some(vs) => @Assert(vs.value, expected[i])
                case None => @Fail("big-${i} 重开后新写入读不到")
            }
        }
        db2.close()

        let db3 = Badger.open(opt)
        for (i in 0..15) {
            match (db3.get("big-${i}".toArray())) {
                case Some(vs) => @Assert(vs.value, expected[i])
                case None => @Fail("big-${i} 二次重开后缺失")
            }
        }
        db3.close()
        cleanupDir(dir)
    }

    // 重开后覆盖写同一个 key 的大值：必须读到新值（而不是段首旧值），并且关掉重开仍为新值。
    @TestCase
    func testUpdatedLargeValueSurvivesReopen() {
        let dir = "/tmp/badger_vlog_reopen_update"
        cleanupDir(dir)
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64, valueThreshold: 1024u64)

        let first = vlogReopenDbValue("first-", 2048)
        let second = vlogReopenDbValue("second-", 3072)
        let db1 = Badger.open(opt)
        db1.updateOrThrow({ txn => txn.set("k".toArray(), first) })
        db1.close()

        let db2 = Badger.open(opt)
        match (db2.get("k".toArray())) {
            case Some(vs) => @Assert(vs.value, first)
            case None => @Fail("k 重开后缺失")
        }
        db2.updateOrThrow({ txn => txn.set("k".toArray(), second) })
        match (db2.get("k".toArray())) {
            case Some(vs) => @Assert(vs.value, second)
            case None => @Fail("k 更新后缺失")
        }
        db2.close()

        let db3 = Badger.open(opt)
        match (db3.get("k".toArray())) {
            case Some(vs) => @Assert(vs.value, second)
            case None => @Fail("k 再次重开后缺失")
        }
        db3.close()
        cleanupDir(dir)
    }
}
