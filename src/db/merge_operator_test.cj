package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.convert.*
import std.sync.*
import std.time.*

// MergeOperator（阶段 5.2）：add 追加 merge 位增量，get 折叠读取，后台折叠回写 discard 位版本，
// compaction 之后旧 merge 链被回收。
@Test
class MergeOperatorTest {
    @TestCase
    func testCounterMergeAndBackgroundCompaction(): Unit {
        let dir = "/tmp/badger_merge_counter"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64, numLevelZeroTables: 1))
        let op = db.getMergeOperator("counter".toArray(), sumInts, interval: Duration.millisecond * 20)
        op.add("1".toArray())
        op.add("2".toArray())
        op.add("3".toArray())
        @Assert(String.fromUtf8(op.get()), "6")

        // 后台折叠线程跑几轮后结果不变（折叠是幂等语义）
        sleep(Duration.millisecond * 150)
        @Assert(String.fromUtf8(op.get()), "6")

        op.add("4".toArray())
        @Assert(String.fromUtf8(op.get()), "10")

        op.stop()
        db.close()
        cleanupDir(dir)
    }

    @TestCase
    func testGetBeforeAddThrowsNotFound(): Unit {
        let dir = "/tmp/badger_merge_notfound"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))
        let op = db.getMergeOperator("missing".toArray(), sumInts, interval: Duration.millisecond * 20)
        var thrown = false
        try {
            op.get()
        } catch (e: Exception) {
            thrown = true
        }
        @Assert(thrown, true)
        op.stop()
        db.close()
        cleanupDir(dir)
    }

    @TestCase
    func testMergeSurvivesReopen(): Unit {
        let dir = "/tmp/badger_merge_reopen"
        cleanupDir(dir)
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        let op = db.getMergeOperator("counter".toArray(), sumInts, interval: Duration.millisecond * 20)
        op.add("10".toArray())
        op.add("20".toArray())
        op.add("30".toArray())
        op.stop()
        db.close()

        let db2 = Badger.open(opt)
        let op2 = db2.getMergeOperator("counter".toArray(), sumInts, interval: Duration.millisecond * 20)
        @Assert(String.fromUtf8(op2.get()), "60")
        op2.add("40".toArray())
        @Assert(String.fromUtf8(op2.get()), "100")
        op2.stop()
        db2.close()
        cleanupDir(dir)
    }

    @TestCase
    func testDeleteResetsFold(): Unit {
        let dir = "/tmp/badger_merge_delete"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))
        let op = db.getMergeOperator("counter".toArray(), sumInts, interval: Duration.millisecond * 20)
        op.add("1".toArray())
        op.add("2".toArray())
        @Assert(String.fromUtf8(op.get()), "3")

        db.updateOrThrow({ txn => txn.delete("counter".toArray()) })
        var thrown = false
        try {
            op.get()
        } catch (e: Exception) {
            thrown = true
        }
        @Assert(thrown, true)

        op.add("5".toArray())
        @Assert(String.fromUtf8(op.get()), "5")
        op.stop()
        db.close()
        cleanupDir(dir)
    }

    @TestCase
    func testCompactionReclaimsMergeEntries(): Unit {
        let dir = "/tmp/badger_merge_reclaim"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64, numLevelZeroTables: 1))
        let op = db.getMergeOperator("counter".toArray(), sumInts, interval: Duration.second)
        for (i in 1..6) {
            op.add(i.toString().toArray())
        }
        @Assert(String.fromUtf8(op.get()), "15")

        // 手动折叠成一条 discard 位条目，再落两张 L0 表触发 compaction
        op.compact()
        db.flushMemTable()
        db.updateOrThrow({ txn => txn.set("other".toArray(), "1".toArray()) })
        db.flushMemTable()
        db.compact()

        @Assert(countVersionsOf(db, "counter"), 1)
        @Assert(String.fromUtf8(op.get()), "15")
        op.stop()
        db.close()
        cleanupDir(dir)
    }
}

func sumInts(existing: Array<Byte>, incoming: Array<Byte>): Array<Byte> {
    let a = Int64.parse(String.fromUtf8(existing))
    let b = Int64.parse(String.fromUtf8(incoming))
    (a + b).toString().toArray()
}
