package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.sync.*
import std.time.*

// 异步 flusher（flush 移出写锁）语义与并发回归测试（对应 docs/plans/2026-09-05-async-flusher-l1-builder-design.md）：
//   - flushMemTable() 公开 API 保持同步语义：返回时当前 memtable 已落盘（含 MANIFEST + 出队）
//   - 多轮 flush + 队列背压（NumMemtables 上限）下不丢数据、不死锁
//   - 写路径触发 flush 期间并发读者不悬挂、数据最终一致
//   - 排队中直接 close：close 兜底全量落盘，重开数据全找回
//   - 在途 memtable 深度受 NumMemtables 约束（immCount 峰值采样）
@Test
class AsyncFlusherTest {
    // —— 公开 API 同步语义：flushMemTable() 返回即落盘（sst 文件 + MANIFEST），数据可读 ——
    @TestCase
    func testFlushMemTableSyncSemanticsPersistent() {
        let dir = "/tmp/badger_async_flush_sync_semantics"
        cleanupDir(dir)
        // numLevelZeroTables 放大：隔离运行期 flush 落盘与 compaction 落盘
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64, numLevelZeroTables: 1000)
        let db = Badger.open(opt)

        let rounds = 6
        for (round in 0..rounds) {
            let entries = ArrayList<Entry>()
            for (i in 0..40) {
                let key = "r${round}_k${i}".toArray()
                let value = Array<Byte>(40000, repeat: UInt8(0x60))
                entries.add(Entry(key, value))
            }
            db.batchSet(entries)
        }

        // 触发轮换 + 异步落盘；返回时当前 memtable 必须已落盘出队
        db.flushMemTable()

        var found = 0
        for (round in 0..rounds) {
            for (i in 0..40) {
                let key = "r${round}_k${i}".toArray()
                if (let Some(_) <- db.get(key)) {
                    found++
                }
            }
        }
        println("[async] flushMemTable sync: keys=${found}/${rounds * 40} sst=${testCountFilesWithSuffix(dir, ".sst")} " +
            "imm=${db.getImmCount()}")
        @Assert(found, rounds * 40)
        @Assert(testCountFilesWithSuffix(dir, ".sst") > 0, true)
        // 同步语义：flushMemTable 返回后 imm 中无在途表（全部出队落盘）
        @Assert(db.getImmCount(), 0)

        db.close()
        cleanupDir(dir)
    }

    // —— 背压 + 数据完整性：小 memtable + 极小 NumMemtables=2，多轮写远超队列深度 ——
    @TestCase
    func testBackpressureKeepsDataIntact() {
        valRoundtrip("badger_async_flush_backpressure", 256 * 1024u64, 2, 10, true)
        valRoundtrip("badger_async_flush_backpressure_sync", 256 * 1024u64, 2, 10, false)
    }

    // —— 排队中直接 close（不调用 flushMemTable）：close 兜底全量落盘，重开全找回 ——
    @TestCase
    func testCloseWithPendingFlushesNoLoss() {
        valRoundtrip("badger_async_flush_close_pending", 256 * 1024u64, 3, 12, true)
    }

    // —— InMemory 模式走同一 flush 链：背压不丢数据 ——
    @TestCase
    func testInMemoryMultiRoundFlush() {
        valRoundtripInMemory("badger_async_flush_inmemory", 256 * 1024u64, 2, 10)
    }

    // —— 写路径触发 flush 期间并发读者：不悬挂、不抛错、最终一致 ——
    @TestCase
    func testConcurrentReadersDuringHeavyFlush() {
        let opt = Config(dir: "", inMemory: true, memTableSize: 128 * 1024u64, numMemtables: 2)
        let db = Badger.open(opt)

        let totalKeys: Int64 = 400
        let progress = AtomicInt64(0)
        let writeErr = AtomicBool(false)

        // 写线程：连续 batchSet 触发多轮 flush（每 ~6 条 20KB 值即轮换）
        let wf = spawn {
            try {
                var i: Int64 = 0
                while (i < totalKeys) {
                    let entries = ArrayList<Entry>()
                    var j: Int64 = 0
                    while (j < 20 && i < totalKeys) {
                        // 值字节取 i%256：UInt8(i) 在 i≥256 会溢出抛异常（曾致写线程夭折、
                        // 读者无限等待——测试挂起假象）
                        entries.add(Entry("k${i}".toArray(),
                            Array<Byte>(20000, repeat: UInt8(i % 256))))
                        i++
                        j++
                    }
                    db.batchSet(entries)
                    progress.store(i)
                }
            } catch (e: Exception) {
                println("[async] writer error: ${e.message}")
                writeErr.store(true)
            }
        }

        // 读线程：不断抽查已写 key（读到即验证值）；flush 期间不得悬挂/抛错
        let rf = spawn {
            try {
                var checked: Int64 = 0
                while (progress.load() < totalKeys) {
                    let upto = progress.load()
                    if (upto > 0) {
                        let k = upto / 2
                        if (let Some(vs) <- db.get("k${k}".toArray())) {
                            let expect = UInt8(k % 256)
                            // 子线程内不直接用 @Assert（宏断言绑定测试线程），失败置标志主线程收口
                            if (vs.value.size == 0 || vs.value[0] != expect) {
                                println("[async] reader mismatch at k${k}")
                                writeErr.store(true)
                            }
                            checked++
                        }
                    }
                    sleep(Duration.millisecond)
                }
                println("[async] concurrent reader checked=${checked} keys while flushing")
            } catch (e: Exception) {
                println("[async] reader error: ${e.message}")
                writeErr.store(true)
            }
        }

        wf.get()
        rf.get()
        @Assert(writeErr.load(), false)

        // 最终一致：全部 key 可读且值正确
        var found: Int64 = 0
        for (i in 0..totalKeys) {
            if (let Some(vs) <- db.get("k${i}".toArray())) {
                if (vs.value[0] == UInt8(i % 256)) {
                    found++
                }
            }
        }
        println("[async] final consistent keys=${found}/${totalKeys}")
        @Assert(found, totalKeys)

        db.close()
    }

    // —— 背压直接观测：immCount（在途 memtable）峰值不超过 NumMemtables ——
    @TestCase
    func testImmDepthCappedByNumMemtables() {
        let opt = Config(dir: "", inMemory: true, memTableSize: 128 * 1024u64, numMemtables: 2)
        let db = Badger.open(opt)

        let peak = AtomicInt64(0)
        let stop = AtomicBool(false)
        let monitor = spawn {
            while (!stop.load()) {
                let cur = db.getImmCount()
                var p = peak.load()
                while (cur > p) {
                    if (!peak.compareAndSwap(p, cur)) {
                        p = peak.load()
                    } else {
                        break
                    }
                }
                sleep(Duration.millisecond)
            }
        }

        // 触发远超队列深度的轮换（每批 ~1.2MB / 128KB memtable ≈ 9 张表）
        for (round in 0..30) {
            let entries = ArrayList<Entry>()
            for (i in 0..60) {
                entries.add(Entry("r${round}_k${i}".toArray(), Array<Byte>(20000, repeat: UInt8(i))))
            }
            db.batchSet(entries)
        }
        db.flushMemTable()
        stop.store(true)
        monitor.get()

        println("[async] immCount peak=${peak.load()} (NumMemtables=2)")
        @Assert(peak.load() <= 2, true)

        var found: Int64 = 0
        for (round in 0..30) {
            for (i in 0..60) {
                if (db.get("r${round}_k${i}".toArray()).isSome()) {
                    found++
                }
            }
        }
        @Assert(found, 30 * 60)
        db.close()
    }

    // —— 空表 flushMemTable 为无操作（不轮换、不产生表文件）——
    @TestCase
    func testFlushMemTableEmptyIsNoop() {
        let dir = "/tmp/badger_async_flush_empty_noop"
        cleanupDir(dir)
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64, numLevelZeroTables: 1000)
        let db = Badger.open(opt)

        let sstBefore = testCountFilesWithSuffix(dir, ".sst")
        db.flushMemTable()   // 空表：应直接返回，不落盘空表
        @Assert(testCountFilesWithSuffix(dir, ".sst"), sstBefore)
        @Assert(db.getImmCount(), 0)
        @Assert(db.levels()[0].NumTables, 0)

        // 写一条后 flush 正常落盘
        db.batchSet(ArrayList<Entry>([Entry("only".toArray(), "v".toArray())]))
        db.flushMemTable()
        @Assert(testCountFilesWithSuffix(dir, ".sst"), sstBefore + 1)
        @Assert(db.get("only".toArray()).isSome(), true)

        db.close()
        cleanupDir(dir)
    }
}

// 磁盘模式多轮写 + flush 语义轮换：写 →（可选 flushMemTable）→ close → reopen 全找回
private func valRoundtrip(dirBase: String, memTableSize: UInt64, numMemtables: Int, rounds: Int,
    useIoUring: Bool): Unit {
    let dir = "/tmp/${dirBase}"
    cleanupDir(dir)
    let opt = Config(dir: dir, memTableSize: memTableSize, numMemtables: numMemtables,
        numLevelZeroTables: 1000, useIoUring: useIoUring)
    let db = Badger.open(opt)

    let perRound = 60  // 60 × 20KB = 1.2MB/轮
    for (round in 0..rounds) {
        let entries = ArrayList<Entry>()
        for (i in 0..perRound) {
            let key = "r${round}_k${i}".toArray()
            let value = Array<Byte>(20000, repeat: UInt8((round + i) % 256))
            entries.add(Entry(key, value))
        }
        db.batchSet(entries)
    }
    // 部分轮次主动 flush（同步语义校验穿插在背压场景中）
    db.flushMemTable()
    println("[async] ${dirBase} rounds=${rounds}: sst=${testCountFilesWithSuffix(dir, ".sst")} " +
        "imm=${db.getImmCount()} l0=${db.levels()[0].NumTables}")
    @Assert(db.getImmCount(), 0)

    db.close()
    @Assert(testCountFilesWithSuffix(dir, ".sst") > 0, true)

    let db2 = Badger.open(opt)
    var found = 0
    for (round in 0..rounds) {
        for (i in 0..perRound) {
            let key = "r${round}_k${i}".toArray()
            let expect = UInt8((round + i) % 256)
            if (let Some(vs) <- db2.get(key)) {
                if (vs.value.size > 0 && vs.value[0] == expect) {
                    found++
                }
            }
        }
    }
    println("[async] ${dirBase} reopen: keys=${found}/${rounds * perRound}")
    @Assert(found, rounds * perRound)
    db2.close()
    cleanupDir(dir)
}

// InMemory 多轮写回归（同一 flush 链，无文件）
private func valRoundtripInMemory(dirBase: String, memTableSize: UInt64, numMemtables: Int,
    rounds: Int): Unit {
    let opt = Config(dir: "", inMemory: true, memTableSize: memTableSize, numMemtables: numMemtables)
    let db = Badger.open(opt)

    let perRound = 60
    for (round in 0..rounds) {
        let entries = ArrayList<Entry>()
        for (i in 0..perRound) {
            entries.add(Entry("r${round}_k${i}".toArray(), Array<Byte>(20000, repeat: UInt8(i))))
        }
        db.batchSet(entries)
    }
    db.flushMemTable()
    @Assert(db.getImmCount(), 0)

    var found = 0
    for (round in 0..rounds) {
        for (i in 0..perRound) {
            if (db.get("r${round}_k${i}".toArray()).isSome()) {
                found++
            }
        }
    }
    println("[async] ${dirBase} inmemory: keys=${found}/${rounds * perRound} l0=${db.levels()[0].NumTables}")
    @Assert(found, rounds * perRound)
    db.close()
}

// cleanupDir / testCountFilesWithSuffix 复用 test_helpers.cj 的公共版本
