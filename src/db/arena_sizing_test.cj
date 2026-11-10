package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*

// 2.3：arena 目标容量公式（批次预留封顶 2MB + 可配）与「批次大于预留」的正确性。
//
// 背景：arena 底层是 Array<Byte>（GC 堆内存），目标 = MemTableSize + 批次预留 + 节点项。
// 2.2 及以前按 15% 走，64MB 表就是 20.6MB 预留，而实测单批最大预留只有 28KB~1.65MB
// （128B/1KB/16KB 值 × 100~1000 条/事务）——那部分平时不用，却是实打实的堆占用。
@Test
class ArenaSizingTest {
    private func keyBytes(i: Int64): Array<Byte> {
        let raw = i.toString()
        let pad = 8 - raw.size
        ("as-" + String.fromUtf8(Array<Byte>(pad, repeat: 0x30)) + raw).toArray()
    }

    @TestCase
    func testReserveCappedAtTwoMegabytes(): Unit {
        let opt = Config(memTableSize: 64 * 1024 * 1024u64)
        let reserve = arenaBatchReserveBytes(opt)
        // 15% × 64MB = 9.6MB，2.3 起封顶 2MB
        @Assert(reserve, 2 * 1024 * 1024)
        let target = arenaTargetBytes(opt)
        // 目标 = MT + 预留 + 节点项（= 预留/96 × 106 ≈ 2.2MB）；合计开销 ≈ 4.2MB（+6.6%），
        // 远小于 2.2 的 20.6MB（+31.6%）
        @Assert(target - Int64(opt.MemTableSize) - reserve, (reserve / 96) * 106)
        @Assert(target < Int64(opt.MemTableSize) + 5 * 1024 * 1024, true)
        println("[arena-sizing] mt=64MB reserve=" + reserve.toString() + " target=" + target.toString())
    }

    @TestCase
    func testSmallTableKeepsFifteenPercent(): Unit {
        // 4MB 表：15% = 629145B < 2MB 上限 → 与 2.2 行为一致
        let opt = Config(memTableSize: 4 * 1024 * 1024u64)
        @Assert(arenaBatchReserveBytes(opt), Int64(4 * 1024 * 1024) * 15 / 100)
    }

    @TestCase
    func testExplicitReserveConfigAndClamp(): Unit {
        let mt: UInt64 = 4 * 1024 * 1024u64
        // 显式值 > MemTableSize → 截到 MemTableSize（预留不该超过表本身）
        let big = Config(memTableSize: mt, memTableBatchReserveBytes: 8 * 1024 * 1024u64)
        @Assert(arenaBatchReserveBytes(big), Int64(mt))
        // 显式值生效（不再按 15%）
        let small = Config(memTableSize: mt, memTableBatchReserveBytes: 512 * 1024u64)
        @Assert(arenaBatchReserveBytes(small), Int64(512 * 1024))
    }

    @TestCase
    func testStreamingSSTableDefaultsOn(): Unit {
        // 2.3 起默认开（吞吐无代价、峰值内存显著更低）；关掉可回退旧路径
        @Assert(Config().StreamingSSTable, true)
        @Assert(Config(streamingSSTable: false).StreamingSSTable, false)
    }

    // 批次远大于预留：写路径必须按「放不下就轮换重试」走完，一条都不能丢
    @TestCase
    func testBatchLargerThanReserveStillWritten(): Unit {
        let dir = "/tmp/badger_arena_reserve_batch"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 4 * 1024 * 1024u64, numLevelZeroTables: 1000))
        let value = Array<Byte>(1024, repeat: 0x5A)
        // 8000 条 × ~1.2KB 预留 ≈ 9.6MB，跨 2~3 张 4MB 表
        let n: Int64 = 8000
        db.updateOrThrow({ txn =>
            var i: Int64 = 0
            while (i < n) {
                txn.set(keyBytes(i), value)
                i++
            }
        })
        var ok: Int64 = 0
        for (i in 0..n) {
            if (db.get(keyBytes(i)).isSome()) {
                ok++
            }
        }
        @Assert(ok, n)
        println("[arena-sizing] big-batch tables=" + db.tables().size.toString() + " ok=" + ok.toString())
        db.close()
        cleanupDir(dir)
    }

    // 小批次但值很大（单批字节 > 预留、仍小于 arena）：不轮换也应写入成功
    @TestCase
    func testBatchBytesExceedReserveButFitArena(): Unit {
        let dir = "/tmp/badger_arena_reserve_values"
        cleanupDir(dir)
        // 4MB 表 → 默认预留 629KB；每批 100 条 × 8KB = 800KB > 预留
        let db = Badger.open(Config(dir: dir, memTableSize: 4 * 1024 * 1024u64,
            numLevelZeroTables: 1000, valueThreshold: 64 * 1024u64))
        let value = Array<Byte>(8 * 1024, repeat: 0x33)
        let n: Int64 = 100
        db.updateOrThrow({ txn =>
            var i: Int64 = 0
            while (i < n) {
                txn.set(keyBytes(i), value)
                i++
            }
        })
        var ok: Int64 = 0
        for (i in 0..n) {
            if (db.get(keyBytes(i)).isSome()) {
                ok++
            }
        }
        @Assert(ok, n)
        db.close()
        cleanupDir(dir)
    }
}
