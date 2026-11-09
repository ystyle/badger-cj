package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*

// Pebble 式 arena 渐进扩容：第一张 memtable 256KB 起，每轮翻倍，封顶目标值。
@Test
class ArenaGrowthTest {
    private func key(i: Int64): Array<Byte> {
        let raw = i.toString()
        let pad = 6 - raw.size
        ("ag-" + String.fromUtf8(Array<Byte>(pad, repeat: 0x30)) + raw).toArray()
    }


    @TestCase
    func testGrowthCanBeDisabled(): Unit {
        let dir = "/tmp/badger_arena_growth_off"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 1024 * 1024u64, arenaGrowthStartBytes: 0))
        let first = db.getMemTable().remainingArena()
        println("[arena-growth] disabled first=" + first.toString())
        // 关闭渐进：直接用目标值（1.32x MemTableSize）
        @Assert(first > 1300 * 1024, true)
        db.close()
        cleanupDir(dir)
    }

    @TestCase
    func testGrowthCustomStart(): Unit {
        let dir = "/tmp/badger_arena_growth_custom"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 1024 * 1024u64,
            arenaGrowthStartBytes: 64 * 1024u64))
        let first = db.getMemTable().remainingArena()
        println("[arena-growth] custom first=" + first.toString())
        // 自定义起点 64KB（扣掉 arena 头部后约 63KB）
        @Assert(first > 48 * 1024, true)
        @Assert(first < 96 * 1024, true)
        db.close()
        cleanupDir(dir)
    }

    @TestCase
    func testArenaDoublesUntilTarget(): Unit {
        let dir = "/tmp/badger_arena_growth"
        cleanupDir(dir)
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64, numLevelZeroTables: 64)
        let db = Badger.open(opt)
        let first = db.getMemTable().remainingArena()
        println("[arena-growth] first=" + first.toString())
        @Assert(first > 200 * 1024, true)
        @Assert(first < 300 * 1024, true)

        var last = first
        let value = Array<Byte>(100, repeat: 0x42)
        var written: Int64 = 0
        var rounds: Int64 = 0
        while (rounds < 6) {
            var i: Int64 = 0
            while (i < 4000) {
                let start = written
                db.updateOrThrow({ txn =>
                    var j: Int64 = 0
                    while (j < 100) {
                        txn.set(key(start + j), value)
                        j++
                    }
                })
                written += 100
                i += 100
            }
            db.flushMemTable()
            let cur = db.getMemTable().remainingArena()
            println("[arena-growth] size=" + cur.toString())
            @Assert(cur >= last, true)
            last = cur
            rounds++
        }
        db.close()
        // 渐进扩容最终应到目标附近（>= 1MB）
        @Assert(last >= 1024 * 1024, true)
        cleanupDir(dir)
    }
}
