package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*

// Issue 复现（docs/issue/2026-09-02-flush-no-persist-oom-mcp-hang.md）：
// 运行期 memtable flush 只建内存 L0 表（flushToLevel），不落盘、不更新 MANIFEST，
// L0 内存表随 flush 单调增长（无 compaction 时）→ 长时间运行 OOM。
//
// 本测试以「运行期 flush 应落盘」为预期（对齐 badger-go 语义、修复后的目标行为）：
// 当前实现下断言失败即完成复现；修复后本测试应原样通过（回归保护）。
@Test
class FlushPersistRegressionTest {
    private let valueSize = 40000
    private let entriesPerRound = 40  // 40KB × 40 ≈ 1.6MB / 轮

    // 核心复现：正常运行（不 close、无 compaction）时，flush 必须把 memtable 写盘成
    // .sst 并记录到 MANIFEST。当前实现只 addTable 到 L0（内存）→ 断言失败 = 复现。
    @TestCase
    func testRuntimeFlushShouldWriteSstAndManifest() {
        let dir = "/tmp/badger_flush_repro_runtime"
        cleanupDir(dir)
        // numLevelZeroTables 放大：隔离「flush 落盘」与「compaction 落盘」两条路径，
        // 保证观测到的磁盘文件只可能来自运行期 flush。
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64, numLevelZeroTables: 1000)
        let db = Badger.open(opt)

        let rounds = 8
        for (round in 0..rounds) {
            let entries = ArrayList<Entry>()
            for (i in 0..entriesPerRound) {
                let key = "r${round}_k${i}".toArray()
                let value = Array<Byte>(valueSize, repeat: UInt8(0x50))
                entries.add(Entry(key, value))
            }
            db.batchSet(entries)
            // L0 内存表数 = 已发生的 flush 次数（无 compaction 时只增不减）
            println("[repro] round ${round}: L0 tables=${db.levels()[0].NumTables} " +
                "sstOnDisk=${testCountFilesWithSuffix(dir, ".sst")} memFiles=${testCountFilesWithSuffix(dir, ".mem")}")
        }

        let l0Tables = db.levels()[0].NumTables
        let sstCount = testCountFilesWithSuffix(dir, ".sst")
        let manifestBytes = testFileBytesSize(dir + "/MANIFEST")
        println("[repro] FINAL L0 in-memory tables=${l0Tables} sstOnDisk=${sstCount} " +
            "MANIFEST bytes=${manifestBytes}")

        // 确实发生了多次 flush（≥2），观测才有意义
        @Assert(l0Tables >= 2, true)
        // 修复语义：运行期 flush 已落盘
        @Assert(sstCount > 0, true)
        @Assert(manifestBytes > 0, true)

        db.close()
        cleanupDir(dir)
    }

    // 对照：close 路径落盘正常（issue 已观察到 docker stop 后 close 写出 .sst +
    // MANIFEST），证明降级/同步写盘本身可用；重启后数据完整。
    // 同步写（useIoUring=false）应完整；io_uring 批量写路径（默认）若丢数据则一并暴露。
    @TestCase
    func testCloseFlushPersistsAndReopenReadsAll() {
        flushReproCloseRoundtrip("badger_flush_repro_close_sync", false)
        flushReproCloseRoundtrip("badger_flush_repro_close_uring", true)
    }

    // 崩溃语义（对齐 badger-go）：运行期 flush 已落盘的数据不依赖 close——
    // 不 close 直接重开（模拟 kill -9 后重启），全部 key 都应找回：
    //  ① flush 落盘表：由 manifest + .sst 恢复
    //  ② 未 flush 的当前 memtable：由 WAL 重放恢复（open 后立即 flush 落盘）
    @TestCase
    func testFlushedDataSurvivesReopenWithoutClose() {
        let dir = "/tmp/badger_flush_repro_crash"
        cleanupDir(dir)
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64, numLevelZeroTables: 1000)
        let db1 = Badger.open(opt)

        let rounds = 4
        for (round in 0..rounds) {
            let entries = ArrayList<Entry>()
            for (i in 0..40) {
                let key = "r${round}_k${i}".toArray()
                let value = Array<Byte>(valueSize, repeat: UInt8(0x52))
                entries.add(Entry(key, value))
            }
            db1.batchSet(entries)
        }
        // 模拟崩溃：不 close db1。先把当前 memtable 的 WAL 缓冲刷盘（进程消失前的
        // 最后落盘），随后的重开 = replay WAL + manifest 恢复
        db1.flushWAL()

        let db2 = Badger.open(opt)
        var found = 0
        for (round in 0..rounds) {
            for (i in 0..40) {
                let key = "r${round}_k${i}".toArray()
                if (let Some(_) <- db2.get(key)) {
                    found++
                }
            }
        }
        println("[repro] reopen-without-close: keys=${found}/160")
        @Assert(found, 160)
        db2.close()
        cleanupDir(dir)
    }
}

private func flushReproCloseRoundtrip(dirBase: String, useIoUring: Bool): Unit {
    let dir = "/tmp/${dirBase}"
    cleanupDir(dir)
    let opt = Config(dir: dir, memTableSize: 1024 * 1024u64, numLevelZeroTables: 1000,
        useIoUring: useIoUring)
    let db = Badger.open(opt)

    let rounds = 4
    for (round in 0..rounds) {
        let entries = ArrayList<Entry>()
        for (i in 0..40) {
            let key = "r${round}_k${i}".toArray()
            let value = Array<Byte>(40000, repeat: UInt8(0x51))
            entries.add(Entry(key, value))
        }
        db.batchSet(entries)
    }
    db.close()

    let sstAfterClose = testCountFilesWithSuffix(dir, ".sst")
    let manifestBytes = testFileBytesSize(dir + "/MANIFEST")
    println("[repro] useIoUring=${useIoUring} after close: sstOnDisk=${sstAfterClose} " +
        "MANIFEST bytes=${manifestBytes} sizes=${testDirFileSnapshot(dir)}")
    @Assert(sstAfterClose > 0, true)
    @Assert(manifestBytes > 0, true)

    let db2 = Badger.open(opt)
    var found = 0
    var perRound = ""
    for (round in 0..rounds) {
        var roundFound = 0
        for (i in 0..40) {
            let key = "r${round}_k${i}".toArray()
            if (let Some(_) <- db2.get(key)) {
                found++
                roundFound++
            }
        }
        perRound += " r${round}=${roundFound}/40"
    }
    var tableDesc = ""
    for (ti in db2.tables()) {
        tableDesc += " [id=${ti.ID} lvl=${ti.Level} keys=${ti.KeyCount}]"
    }
    println("[repro] useIoUring=${useIoUring} reopened tables:${tableDesc}")
    println("[repro] useIoUring=${useIoUring} after reopen: keys=${found}/160 rounds:${perRound}")
    @Assert(found, 160)
    db2.close()
    cleanupDir(dir)
}

