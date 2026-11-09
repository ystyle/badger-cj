package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.sync.*

// 分组提交（阶段 4）：同一写管道批次内的多个请求共享「一次 WAL 映射写 + 一次 msync」。
// 这些用例从外部语义钉住：SyncWrites 下的持久性、跨 memtable 轮换的正确性、覆盖写版本。
@Test
class GroupCommitTest {
    @TestCase
    func testConcurrentCommitsDurableWithSyncWrites(): Unit {
        let dir = "/tmp/badger_group_commit_durable"
        cleanupDir(dir)
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64, valueThreshold: 64u64,
            numMemtables: 3, syncWrites: true)
        let db = Badger.open(opt)

        let threads = 4
        let perThread = 40
        let futures = ArrayList<Future<Unit>>()
        for (t in 0..threads) {
            futures.add(spawn {
                for (i in 0..perThread) {
                    let key = "t${t}-k${i}"
                    // 128B 值 >= threshold 64 → 走 vlog；同时覆盖 inline 路径的键
                    let value = "t${t}-v${i}-" + repeatChar(0x78, 120)
                    db.updateOrThrow({ txn: Transaction => txn.set(key.toArray(), value.toArray()) })
                }
            })
        }
        for (f in futures) {
            f.get()
        }
        db.close()

        let db2 = Badger.open(opt)
        for (t in 0..threads) {
            for (i in 0..perThread) {
                let key = "t${t}-k${i}"
                let expected = "t${t}-v${i}-" + repeatChar(0x78, 120)
                match (db2.get(key.toArray())) {
                    case Some(vs) => @Assert(String.fromUtf8(vs.value), expected)
                    case None => @Fail("线程 ${t} 的 ${key} 在重开后丢失")
                }
            }
        }
        db2.close()
        cleanupDir(dir)
    }

    @TestCase
    func testBatchAcrossMemTableRotation(): Unit {
        let dir = "/tmp/badger_group_commit_rotation"
        cleanupDir(dir)
        // 8KB memtable：约几十条就轮换，覆盖批内/批间轮换路径
        let opt = Config(dir: dir, memTableSize: 8 * 1024u64, valueThreshold: 512u64,
            numMemtables: 2)
        let db = Badger.open(opt)

        let n: Int64 = 300
        for (i in 0..n) {
            let value = "value-${i}-" + repeatChar(0x79, 48)
            db.updateOrThrow({ txn => txn.set("r-${i}".toArray(), value.toArray()) })
        }
        db.close()

        let db2 = Badger.open(opt)
        for (i in 0..n) {
            let expected = "value-${i}-" + repeatChar(0x79, 48)
            match (db2.get("r-${i}".toArray())) {
                case Some(vs) => @Assert(String.fromUtf8(vs.value), expected)
                case None => @Fail("r-${i} 轮换后丢失")
            }
        }
        db2.close()
        cleanupDir(dir)
    }

    @TestCase
    func testOverwriteKeepsLatestVersion(): Unit {
        let dir = "/tmp/badger_group_commit_version"
        cleanupDir(dir)
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64, valueThreshold: 1024u64)
        let db = Badger.open(opt)
        for (i in 0..50) {
            db.updateOrThrow({ txn => txn.set("hot".toArray(), "v-${i}".toArray()) })
        }
        match (db.get("hot".toArray())) {
            case Some(vs) => @Assert(String.fromUtf8(vs.value), "v-49")
            case None => @Fail("hot 缺失")
        }
        db.flushMemTable()
        match (db.get("hot".toArray())) {
            case Some(vs) => @Assert(String.fromUtf8(vs.value), "v-49")
            case None => @Fail("hot 落盘后缺失")
        }
        db.close()
        let db2 = Badger.open(opt)
        match (db2.get("hot".toArray())) {
            case Some(vs) => @Assert(String.fromUtf8(vs.value), "v-49")
            case None => @Fail("hot 重开后缺失")
        }
        db2.close()
        cleanupDir(dir)
    }
}

func repeatChar(c: Byte, n: Int64): String {
    String.fromUtf8(Array<Byte>(n, repeat: c))
}
