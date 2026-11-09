package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.time.*

// WriteBatch（阶段 4）：用户侧批量写入，按单事务上限自动切分。
@Test
class WriteBatchTest {
    @TestCase
    func testBasicSetFlush(): Unit {
        let dir = "/tmp/badger_write_batch_basic"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))
        let wb = db.newWriteBatch()
        for (i in 0..100) {
            wb.set("k-${i}".toArray(), "v-${i}".toArray())
        }
        wb.flush()
        for (i in 0..100) {
            match (db.get("k-${i}".toArray())) {
                case Some(vs) => @Assert(String.fromUtf8(vs.value), "v-${i}")
                case None => @Fail("k-${i} 缺失")
            }
        }
        wb.delete("k-0".toArray())
        wb.flush()
        @Assert(db.get("k-0".toArray()).isNone(), true)
        db.close()
        cleanupDir(dir)
    }

    @TestCase
    func testAutoSplitUnderSmallMemTable(): Unit {
        let dir = "/tmp/badger_write_batch_split"
        cleanupDir(dir)
        // 8KB memtable → maxBatchSize ≈ 1.2KB，每条 ~224B → 每 5~6 条自动 flush 一次
        let db = Badger.open(Config(dir: dir, memTableSize: 8 * 1024u64, valueThreshold: 1024u64))
        let wb = db.newWriteBatch()
        let value = repeatCharWb(0x7A, 200)
        for (i in 0..60) {
            wb.set("s-${i}".toArray(), value.toArray())
        }
        wb.flush()
        for (i in 0..60) {
            match (db.get("s-${i}".toArray())) {
                case Some(vs) => @Assert(String.fromUtf8(vs.value), value)
                case None => @Fail("自动切分后 s-${i} 丢失")
            }
        }
        db.close()
        cleanupDir(dir)
    }

    @TestCase
    func testCancelDiscardsPending(): Unit {
        let dir = "/tmp/badger_write_batch_cancel"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))
        let wb = db.newWriteBatch()
        wb.set("c-1".toArray(), "v".toArray())
        wb.cancel()
        var thrown = false
        try {
            wb.flush()
        } catch (e: Exception) {
            thrown = true
        }
        @Assert(thrown, true)
        @Assert(db.get("c-1".toArray()).isNone(), true)
        var setThrown = false
        try {
            wb.set("c-2".toArray(), "v".toArray())
        } catch (e: Exception) {
            setThrown = true
        }
        @Assert(setThrown, true)
        db.close()
        cleanupDir(dir)
    }

    @TestCase
    func testErrorSticksAfterFlushFailure(): Unit {
        let dir = "/tmp/badger_write_batch_error"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))
        let wb = db.newWriteBatch()
        // 超长 key（> MaxKeySize）在提交时被写路径拒绝
        let bigKey = Array<Byte>(70000, repeat: 0x6B)
        wb.set(bigKey, "v".toArray())
        var thrown = false
        try {
            wb.flush()
        } catch (e: Exception) {
            thrown = true
        }
        @Assert(thrown, true)
        @Assert(wb.getError().isSome(), true)
        var nextThrown = false
        try {
            wb.set("n".toArray(), "v".toArray())
        } catch (e: Exception) {
            nextThrown = true
        }
        @Assert(nextThrown, true)
        db.close()
        cleanupDir(dir)
    }

    @TestCase
    func testSetEntryPreservesTTL(): Unit {
        let dir = "/tmp/badger_write_batch_ttl"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))
        let wb = db.newWriteBatch()
        wb.setEntry(Entry.new("ttl".toArray(), "alive".toArray()).withTTL(Duration.hour))
        wb.flush()
        match (db.get("ttl".toArray())) {
            case Some(vs) => @Assert(String.fromUtf8(vs.value), "alive")
            case None => @Fail("ttl 键缺失")
        }
        db.close()
        cleanupDir(dir)
    }
}

func repeatCharWb(c: Byte, n: Int64): String {
    String.fromUtf8(Array<Byte>(n, repeat: c))
}
