package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import badgercj.arena.*

// memtable arena 公式回归（对齐 badger-go arenaSize）：
//   MemTableSize + maxBatchSize + maxBatchCount*MaxNodeSize
// 旧实现固定 2x MemTableSize：默认 64MB 时单个 arena 即 128MB，NumMemtables=5 的
// 背压上限下峰值可到约 640MB —— 低堆部署跑不动的直接来源之一。
@Test
class MemtableArenaTest {
    @TestCase
    func testArenaMatchesGoFormula(): Unit {
        let dir = "/tmp/badger_arena_formula"
        cleanupDir(dir)
        Directory.create(Path(dir), recursive: true)
        let m: UInt64 = 1024 * 1024u64
        let opt = Config(dir: dir, memTableSize: m)
        let mt = MemTable(opt, 1, false)

        var maxBatchSize = Int64(m) * 15 / 100
        if (maxBatchSize < 1024) {
            maxBatchSize = 1024
        }
        var maxBatchCount = maxBatchSize / 96
        if (maxBatchCount < 1) {
            maxBatchCount = 1
        }
        // Arena 构造时会先占用一个哨兵头，remaining = 容量 - 头部；这里不绑定头部的
        // 具体字节数，只钉住「arena ≈ go 公式」的上下界（旧实现 2x 会直接越过上界）。
        let total = Int64(m) + maxBatchSize + maxBatchCount * MAX_NODE_SIZE
        let actual = mt.remainingArena()
        println("[arena] actual=" + actual.toString() + " formulaMax=" + total.toString() + " 2xM=" + (Int64(m) * 2).toString())

        @Assert(actual > Int64(m), true)
        @Assert(actual <= total, true)
        // 关键回归：不再按 2 倍分配
        @Assert(actual < Int64(m) * 2, true)
        @Assert(actual < Int64(m) * 15 / 10, true)

        mt.closeWAL()
        cleanupDir(dir)
    }
}
