package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*

// Managed DB（阶段 5.3）：提交/读取时间戳完全由调用方指定（对齐 go OpenManaged /
// NewTransactionAt / CommitAt / SetDiscardTs / NewWriteBatchAt）；不自动分配 ts、不做冲突检测。
@Test
class ManagedDbTest {
    @TestCase
    func testReadAtExplicitTimestamps(): Unit {
        let dir = "/tmp/badger_managed_reads"
        cleanupDir(dir)
        let db = Badger.openManaged(Config(dir: dir, memTableSize: 64 * 1024u64, numVersionsToKeep: 3))

        let t10 = db.newTransactionAt(10, update: true)
        t10.set("k".toArray(), "v10".toArray())
        @Assert(t10.commitAt(10).isOk(), true)

        let t20 = db.newTransactionAt(20, update: true)
        t20.set("k".toArray(), "v20".toArray())
        @Assert(t20.commitAt(20).isOk(), true)

        assertReadAt(db, 15, "k", "v10")
        assertReadAt(db, 25, "k", "v20")
        assertReadAt(db, 5, "k", "")
        assertReadAt(db, 10, "k", "v10")
        assertReadAt(db, 20, "k", "v20")

        // 落盘后按时间戳读同样成立
        db.flushMemTable()
        assertReadAt(db, 15, "k", "v10")
        assertReadAt(db, 25, "k", "v20")

        db.close()
        cleanupDir(dir)
    }

    @TestCase
    func testSetDiscardTsReclaimsOldVersions(): Unit {
        let dir = "/tmp/badger_managed_discard"
        cleanupDir(dir)
        let db = Badger.openManaged(Config(dir: dir, memTableSize: 64 * 1024u64,
            numLevelZeroTables: 1, numVersionsToKeep: 2))

        for (i in 1..4) {
            let ts = UInt64(i * 10)
            let txn = db.newTransactionAt(ts, update: true)
            txn.set("k".toArray(), "v${ts}".toArray())
            @Assert(txn.commitAt(ts).isOk(), true)
            db.flushMemTable()
        }
        db.setDiscardTs(30)
        db.compact()

        // 保留 <= 30 的最新 2 个版本（v30、v20），v10 被回收
        @Assert(countVersionsAt(db, "k", 30), 2)
        assertReadAt(db, 30, "k", "v30")
        assertReadAt(db, 20, "k", "v20")
        assertReadAt(db, 15, "k", "")

        db.close()
        cleanupDir(dir)
    }

    @TestCase
    func testWriteBatchAt(): Unit {
        let dir = "/tmp/badger_managed_batch"
        cleanupDir(dir)
        let db = Badger.openManaged(Config(dir: dir, memTableSize: 64 * 1024u64))

        let wb = db.newWriteBatchAt(50)
        for (i in 0..100) {
            wb.set("k-${i}".toArray(), "v-${i}".toArray())
        }
        wb.flush()

        let rtxn = db.newTransactionAt(50, update: false)
        for (i in 0..100) {
            @Assert(rtxn.get("k-${i}".toArray()).isSome(), true)
        }
        rtxn.discard()

        // 早于写入 ts 的读者看不到
        let old = db.newTransactionAt(40, update: false)
        @Assert(old.get("k-0".toArray()).isNone(), true)
        old.discard()

        db.close()
        cleanupDir(dir)
    }

    @TestCase
    func testApiGuards(): Unit {
        let dir1 = "/tmp/badger_managed_guard_normal"
        cleanupDir(dir1)
        let normal = Badger.open(Config(dir: dir1, memTableSize: 64 * 1024u64))

        var atThrown = false
        try {
            normal.newTransactionAt(1, update: false)
        } catch (e: Exception) {
            atThrown = true
        }
        @Assert(atThrown, true)

        var discardThrown = false
        try {
            normal.setDiscardTs(1)
        } catch (e: Exception) {
            discardThrown = true
        }
        @Assert(discardThrown, true)

        var commitAtThrown = false
        let txn = normal.newTransaction(update: true)
        txn.set("x".toArray(), "1".toArray())
        try {
            txn.commitAt(1)
        } catch (e: Exception) {
            commitAtThrown = true
            txn.rollback()
        }
        @Assert(commitAtThrown, true)
        normal.close()
        cleanupDir(dir1)

        let dir2 = "/tmp/badger_managed_guard_managed"
        cleanupDir(dir2)
        let managed = Badger.openManaged(Config(dir: dir2, memTableSize: 64 * 1024u64))
        @Assert(managed.isManaged(), true)

        var batchThrown = false
        try {
            managed.newWriteBatch()
        } catch (e: Exception) {
            batchThrown = true
        }
        @Assert(batchThrown, true)

        var txnThrown = false
        try {
            managed.newTransaction(update: false)
        } catch (e: Exception) {
            txnThrown = true
        }
        @Assert(txnThrown, true)
        managed.close()
        cleanupDir(dir2)
    }
}

func assertReadAt(db: Badger, ts: UInt64, key: String, expected: String): Unit {
    let txn = db.newTransactionAt(ts, update: false)
    try {
        let got = txn.get(key.toArray())
        if (expected == "") {
            @Assert(got.isNone(), true)
        } else {
            match (got) {
                case Some(value) => @Assert(String.fromUtf8(value), expected)
                case None => @Fail("ts=${ts} 读 ${key} 缺失")
            }
        }
    } finally {
        txn.discard()
    }
}

// managed 库不能开普通读事务（oracle.readTs 会抛），统计版本要用指定 ts
func countVersionsAt(db: Badger, userKey: String, ts: UInt64): Int64 {
    let txn = db.newTransactionAt(ts, update: false)
    let iter = txn.newIterator(opt: IteratorOptions(allVersions: true))
    var n: Int64 = 0
    iter.rewind()
    while (iter.valid()) {
        if (String.fromUtf8(iter.item().keyCopy()) == userKey) {
            n++
        }
        iter.next()
    }
    iter.close()
    txn.discard()
    n
}
