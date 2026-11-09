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

    // 大条目自适应（2.2 修正）：单条比「首张小 arena」大时，arena 必须先长到装得下再轮换。
    //
    // 缺陷形态（渐进扩容首版）：首张 memtable 的 arena 按起点值分配（默认 256KB），
    // 单条内联条目大于它时，「全新 memtable 也放不下」被直接判为超大条目抛错 ——
    // 等于 arena 渐进把大 value 判死（实测：memTableSize=4MB 的默认配置下写入
    // 单个 600KB 内联条目失败，而同一配置在非渐进（arena=目标值 5.3MB）下正常）。
    @TestCase
    func testLargeEntryGrowsArenaBeyondStart(): Unit {
        let dir = "/tmp/badger_arena_growth_big"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 4 * 1024 * 1024u64,
            arenaGrowthStartBytes: 64 * 1024u64, valueThreshold: 2 * 1024 * 1024u64))
        let first = db.getMemTable().remainingArena()
        println("[arena-growth] big-entry first=" + first.toString())
        @Assert(first < 96 * 1024, true)

        // 600KB 内联（< ValueThreshold，进 memtable 不进 vlog），远大于首张 arena
        let big = Array<Byte>(600 * 1024, repeat: 0x5A)
        db.updateOrThrow({ txn => txn.set("big-entry".toArray(), big) })

        let cap = db.getMemTable().arenaCapacity()
        println("[arena-growth] big-entry next arena=" + cap.toString())
        @Assert(cap > 600 * 1024, true)
        let got = db.get("big-entry".toArray())
        @Assert(got.isSome(), true)
        if (let Some(vs) <- got) {
            @Assert(vs.value.size, big.size)
            @Assert(vs.value[0], big[0])
            @Assert(vs.value[vs.value.size - 1], big[big.size - 1])
        }
        db.close()
        cleanupDir(dir)
    }

    // 超过「目标 arena」的单条仍必须明确报错，且写路径保持健康（不静默丢数据）
    @TestCase
    func testEntryLargerThanTargetArenaRejected(): Unit {
        let dir = "/tmp/badger_arena_growth_toolarge"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64,
            arenaGrowthStartBytes: 8 * 1024u64, valueThreshold: 2 * 1024 * 1024u64))
        // 目标 arena 约 84KB，单条 400KB 怎么都装不下
        let big = Array<Byte>(400 * 1024, repeat: 0x5A)
        var msg: Option<String> = None
        try {
            db.updateOrThrow({ txn => txn.set("too-big".toArray(), big) })
        } catch (e: Exception) {
            msg = Some(e.message)
        }
        println("[arena-growth] oversized entry rejected: ${msg}")
        @Assert(msg.isSome(), true)

        // 拒绝后写路径仍健康（无 Error 逃逸、无状态破坏）
        db.updateOrThrow({ txn => txn.set("small".toArray(), "v".toArray()) })
        @Assert(db.get("small".toArray()).isSome(), true)
        db.close()
        cleanupDir(dir)
    }
}
