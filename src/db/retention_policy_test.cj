package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.sync.*
import std.time.*

// compaction 保留策略（阶段 5.1）：
//   - 每个 key 至少保留 NumVersionsToKeep 个 <= discardTs 的版本；
//   - 版本号 > discardTs（活跃读者最小 readTs 或 managed setDiscardTs）的版本必须保留；
//   - tombstone 只在最底层丢弃（既有语义保持不变）。
@Test
class RetentionPolicyTest {
    @TestCase
    func testNumVersionsToKeep(): Unit {
        let dir = "/tmp/badger_retention_versions"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64,
            numLevelZeroTables: 1, numVersionsToKeep: 3, disableWAL: true))

        for (i in 0..5) {
            db.updateOrThrow({ txn => txn.set("k".toArray(), "v-${i}".toArray()) })
            db.flushMemTable()
        }
        @Assert(countVersionsOf(db, "k"), 5)

        // 先把 read watermark 推到最新提交 ts（否则最新版本 > discardTs，会多留一个），
        // 再手动 compaction；否则 compact 只会执行一轮，旧表已进 L1 无法再收敛。
        advanceWatermark(db)
        db.compact()
        // 保留 latest 3 个版本（无活跃读者，全部 5 个都可判丢弃）
        @Assert(countVersionsOf(db, "k"), 3)

        db.close()
        cleanupDir(dir)
    }

    @TestCase
    func testDefaultKeepsSingleVersion(): Unit {
        let dir = "/tmp/badger_retention_default"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64,
            numLevelZeroTables: 1, disableWAL: true))

        for (i in 0..4) {
            db.updateOrThrow({ txn => txn.set("k".toArray(), "v-${i}".toArray()) })
            db.flushMemTable()
        }
        advanceWatermark(db)
        db.compact()
        @Assert(countVersionsOf(db, "k"), 1)
        db.close()
        cleanupDir(dir)
    }

    @TestCase
    func testActiveReaderKeepsOldVersion(): Unit {
        let dir = "/tmp/badger_retention_reader"
        cleanupDir(dir)
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64, numLevelZeroTables: 1, disableWAL: true)
        let db = Badger.open(opt)

        // v0 落盘后开读事务：它的 readTs 成为 discardTs 水位
        db.updateOrThrow({ txn => txn.set("k".toArray(), "v0".toArray()) })
        db.flushMemTable()
        let rtxn = db.newTransaction(update: false)

        for (i in 1..4) {
            db.updateOrThrow({ txn => txn.set("k".toArray(), "v${i}".toArray()) })
            db.flushMemTable()
        }
        db.compact()

        // 旧读事务必须仍能读到 v0（丢弃策略不得越过最小活跃 readTs）
        match (rtxn.get("k".toArray())) {
            case Some(value) => @Assert(String.fromUtf8(value), "v0")
            case None => @Fail("活跃读事务在 compaction 后丢失旧版本")
        }
        rtxn.discard()

        // 默认配置：最新读总是最新版本
        match (db.get("k".toArray())) {
            case Some(vs) => @Assert(String.fromUtf8(vs.value), "v3")
            case None => @Fail("最新版本缺失")
        }

        db.close()
        cleanupDir(dir)
    }
}

func countVersionsOf(db: Badger, userKey: String): Int64 {
    let txn = db.newTransaction(update: false)
    let iter = txn.newIterator(opt: IteratorOptions(allVersions: true))
    var n: Int64 = 0
    iter.rewind()
    while (iter.valid()) {
        let item = iter.item()
        if (String.fromUtf8(item.keyCopy()) == userKey) {
            n++
        }
        iter.next()
    }
    iter.close()
    txn.discard()
    n
}

func advanceWatermark(db: Badger): Unit {
    let txn = db.newTransaction(update: false)
    txn.discard()
}
