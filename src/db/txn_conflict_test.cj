package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*

// 冲突检测语义回归（对齐 badger-go）：
// 1. 顺序事务「读到自己上一版 → 重写同 key」不算冲突（修复前误判，
//    物化幂等重写第二次必抛 TxnConflict —— "桶点不开"根因之一）；
// 2. 真正并发交错（readTs 之后他人提交同 key）仍须检测冲突（不放松）。
@Test
class TxnConflictSemanticsTest {

    private let dir = "/tmp/badger_txn_conflict_semantics_test"

    private func cleanup(): Unit {
        let path = Path(dir)
        if (exists(path)) {
            remove(path, recursive: true)
        }
    }

    @TestCase
    func testSequentialReadRewriteNotConflict(): Unit {
        cleanup()
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))
        db.update({ t => t.set("k".toArray(), "v1".toArray()) })
        // 顺序事务：读 k（记录 reads）后重写 k（模拟物化 deleteRefRows：迭代旧行再写回）
        let txn = db.newTransaction(update: true)
        let old = txn.get("k".toArray())
        @Assert(old.isSome(), true)
        txn.set("k".toArray(), "v2".toArray())
        let status = txn.commit()
        @Assert(status.isOk(), true)
        db.close()
        cleanup()
    }

    @TestCase
    func testConcurrentInterleaveStillConflict(): Unit {
        cleanup()
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))
        db.update({ t => t.set("k".toArray(), "v0".toArray()) })
        // txnA 先读（readTs 固定）→ 他人提交同 key → txnA 再写同 key → 必须 Conflict
        let txnA = db.newTransaction(update: true)
        let old = txnA.get("k".toArray())
        @Assert(old.isSome(), true)
        let bRes = db.update({ t => t.set("k".toArray(), "vB".toArray()) })
        @Assert(bRes.isSuccess(), true)
        txnA.set("k".toArray(), "vA".toArray())
        let status = txnA.commit()
        @Assert(status.isConflict(), true)
        db.close()
        cleanup()
    }
}
