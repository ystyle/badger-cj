package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*

// Sequence（阶段 5.4）：租约式单调递增序列（对齐 go GetSequence/Next/Release）。
@Test
class SequenceTest {
    @TestCase
    func testBasicLeaseAndRelease(): Unit {
        let dir = "/tmp/badger_sequence_basic"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))

        let seq = db.getSequence("seq".toArray(), 10)
        @Assert(seq.nextValue(), 0)
        @Assert(seq.nextValue(), 1)
        @Assert(seq.nextValue(), 2)
        seq.release()

        // release 退回未用区间：下一个实例从 3 继续，不产生空洞
        let seq2 = db.getSequence("seq".toArray(), 10)
        @Assert(seq2.nextValue(), 3)
        @Assert(seq2.nextValue(), 4)
        db.close()
        cleanupDir(dir)
    }

    @TestCase
    func testCrashSkipsUnusedLease(): Unit {
        let dir = "/tmp/badger_sequence_crash"
        cleanupDir(dir)
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        let seq = db.getSequence("seq".toArray(), 10)
        @Assert(seq.nextValue(), 0)
        @Assert(seq.nextValue(), 1)
        // 不 release 直接关库（等价进程崩溃）：租约 10 已持久化
        db.close()

        let db2 = Badger.open(opt)
        let seq2 = db2.getSequence("seq".toArray(), 10)
        // 新租约从已持久化的 10 起：跳过 2..9（租约浪费，但保证不回退）
        @Assert(seq2.nextValue(), 10)
        @Assert(seq2.nextValue(), 11)
        db2.close()
        cleanupDir(dir)
    }

    @TestCase
    func testBandwidthOneRenewsEveryValue(): Unit {
        let dir = "/tmp/badger_sequence_band1"
        cleanupDir(dir)
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        let seq = db.getSequence("seq".toArray(), 1)
        @Assert(seq.nextValue(), 0)
        @Assert(seq.nextValue(), 1)
        @Assert(seq.nextValue(), 2)
        db.close()

        // 每条都续租并持久化：重开后从 3 继续（无空洞）
        let db2 = Badger.open(opt)
        let seq2 = db2.getSequence("seq".toArray(), 1)
        @Assert(seq2.nextValue(), 3)
        db2.close()
        cleanupDir(dir)
    }

    @TestCase
    func testIndependentSequences(): Unit {
        let dir = "/tmp/badger_sequence_multi"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))
        let a = db.getSequence("seq-a".toArray(), 5)
        let b = db.getSequence("seq-b".toArray(), 5)
        @Assert(a.nextValue(), 0)
        @Assert(b.nextValue(), 0)
        @Assert(a.nextValue(), 1)
        @Assert(b.nextValue(), 1)
        db.close()
        cleanupDir(dir)
    }

    @TestCase
    func testGuards(): Unit {
        let dir = "/tmp/badger_sequence_guard"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))

        var emptyThrown = false
        try {
            db.getSequence([], 10)
        } catch (e: Exception) {
            emptyThrown = true
        }
        @Assert(emptyThrown, true)

        var bwThrown = false
        try {
            db.getSequence("s".toArray(), 0)
        } catch (e: Exception) {
            bwThrown = true
        }
        @Assert(bwThrown, true)
        db.close()
        cleanupDir(dir)

        let mdir = "/tmp/badger_sequence_guard_managed"
        cleanupDir(mdir)
        let managed = Badger.openManaged(Config(dir: mdir, memTableSize: 64 * 1024u64))
        var managedThrown = false
        try {
            managed.getSequence("s".toArray(), 10)
        } catch (e: Exception) {
            managedThrown = true
        }
        @Assert(managedThrown, true)
        managed.close()
        cleanupDir(mdir)
    }
}
