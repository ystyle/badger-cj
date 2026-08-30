package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*
import badgercj.table.*

// 回归（对齐 badger-go）：
// 1. 单事务条目数超过 memtable 容量时必须条目级 flush（ensureRoomForWrite 语义），
//    不能因 arena 耗尽静默丢弃后续条目（此前 WritePipeline 吞异常 → commit 无条件 Ok → 静默丢数据）。
// 2. 写入失败必须返回 TxnStatus.Error（此前超 64KB 编码上限的 value 写失败却返回成功）。
@Test
class LargeBatchTest {

    private static let DIR = "/tmp/badger_large_batch_test"

    private func cleanup(): Unit {
        let path = Path(DIR)
        if (exists(path)) {
            remove(path, recursive: true)
        }
    }

    private func keyOf(i: Int): Array<Byte> {
        ("key-" + i.toString()).toArray()
    }

    @TestCase
    func testLargeBatchSurvivesMemtableFlush(): Unit {
        cleanup()
        // 64KB memtable：单事务 5000 条远超 arena（2×64KB）容量 → 必然触发多次 flush
        let db = Badger.open(Config(dir: DIR, memTableSize: 64 * 1024u64))
        let txn = db.newTransaction(update: true)
        for (i in 0..5000) {
            txn.set(keyOf(i), ("value-" + i.toString()).toArray())
        }
        let status = txn.commit()
        @Assert(status.isOk(), true)

        // 读回全量（覆盖 mt + 多次 flush 产生的 imm/L0）
        let readTxn = db.newTransaction(update: false)
        var found = 0
        for (i in 0..5000) {
            if (readTxn.get(keyOf(i)).isSome()) {
                found += 1
            }
        }
        @Assert(found, 5000)
        readTxn.discard()
        db.close()
        cleanup()
    }

    @TestCase
    func testOversizeValueFailLoud(): Unit {
        cleanup()
        // value 超 64KB 编码上限（ValueStruct encoded size exceeds UInt16 max）：
        // 文件模式默认 ValueThreshold=1MB → 70KB 值走 memtable 编码 → 必然抛异常
        // （memTableSize 用小值，测试进程默认 GC 堆 256MB 装不下默认 64MB memtable 的 128MB arena）
        let db = Badger.open(Config(dir: DIR, memTableSize: 64 * 1024u64))
        let txn = db.newTransaction(update: true)
        txn.set("big".toArray(), Array<Byte>(70000, repeat: 0u8))
        let status = txn.commit()
        @Assert(status.isError(), true)
        // 失败后库仍可用：下一个事务正常成功
        let okStatus = db.update({ t => t.set("after".toArray(), "ok".toArray()) })
        @Assert(okStatus.isSuccess(), true)
        db.close()
        cleanup()
    }

    @TestCase
    func testWalReplaySkipsOversizeFailedTxn(): Unit {
        cleanup()
        // 构造"失败事务残留 WAL"场景（评审 P1-1 实锤）：
        // WAL 中写一条超 64KB 编码上限的 txn 条目 + finTxn（模拟旧实现：
        // mt.put 抛异常前 WAL 已写入该事务）→ replay 必须跳过坏事务、其余条目照常恢复，
        // 而不能抛异常阻止启动（否则服务重启必崩：.testdata 曾因 112KB 桶记录 112165 崩溃）。
        let dir = DIR + "/replay"
        if (!exists(Path(dir))) {
            Directory.create(Path(dir), recursive: true)
        }
        let walPath = dir + "/0.mem"
        let wal = WAL.open(walPath)
        // 正常条目（非事务）：应恢复
        let okVs = ValueStruct("hello".toArray(), meta: 0, version: 1)
        wal.write("ok".toArray(), okVs.encode())
        // 失败事务：112KB 超限条目 + finTxn（模拟残留）
        let bigVs = ValueStruct(Array<Byte>(70000, repeat: 0u8), meta: Meta.bitTxn, version: 42)
        wal.write("big".toArray(), bigVs.encode())
        let finVs = ValueStruct([], meta: Meta.bitFinTxn, version: 42)
        wal.write(keyWithTs("__txn__".toArray(), 42u64), finVs.encode())
        wal.close()

        // 直接对该 WAL 做 replay（同包可访问 protected 成员）
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let mt = MemTable(opt, 0, false)
        let rw = WAL.openForRead(walPath)
        rw.replay(mt)
        rw.close()

        // 坏事务被跳过、正常条目恢复（replay 不抛异常）
        if (let Some(vs) <- mt.get("ok".toArray())) {
            @Assert(vs.value == "hello".toArray(), true)
        } else {
            @Fail("正常条目必须恢复")
        }
        @Assert(mt.get("big".toArray()).isNone(), true)

        cleanup()
    }
}
