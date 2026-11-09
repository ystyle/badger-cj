package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*

// 2.1 Stats API（P2-1）：读/刷盘/压缩计数与表/缓存快照。
@Test
class StatsTest {
    private func k(i: Int64): Array<Byte> {
        let raw = i.toString()
        let pad = 4 - raw.size
        ("st-" + String.fromUtf8(Array<Byte>(pad, repeat: 0x30)) + raw).toArray()
    }

    @TestCase
    func testStatsCountsAndLevels(): Unit {
        let dir = "/tmp/badger_stats_test"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64,
            numLevelZeroTables: 1, blockCacheSizeMB: 1))
        let value = Array<Byte>(100, repeat: 0x51)
        for (i in 0..200) {
            let key = k(i)
            db.updateOrThrow({ txn => txn.set(key, value) })
        }
        db.flushMemTable()
        // 再写一批并落盘，制造多张 L0 表，便于 compact()
        for (i in 200..400) {
            let key = k(i)
            db.updateOrThrow({ txn => txn.set(key, value) })
        }
        db.flushMemTable()
        db.compact()

        var hits: Int64 = 0
        for (i in 0..100) {
            if (db.get(k(i)).isSome()) {
                hits++
            }
        }
        @Assert(hits, 100)
        let st = db.getStats()
        println("[stats] gets=" + st.Gets.toString() + " flushes=" + st.Flushes.toString() +
            " compactions=" + st.Compactions.toString() + " tables=" + st.TableCount.toString() +
            " cacheUsed=" + st.BlockCache.UsedBytes.toString() +
            " hits=" + st.BlockCache.Hits.toString())
        @Assert(st.Gets > 0, true)
        @Assert(st.Flushes >= 2, true)
        @Assert(st.Compactions >= 1, true)
        @Assert(st.TableCount >= 1, true)
        @Assert(st.BlockCache.UsedBytes > 0, true)
        @Assert(st.Levels.size, 7)
        var sum: Int64 = 0
        for (ls in st.Levels) {
            sum += ls.TableCount
        }
        @Assert(sum, st.TableCount)
        db.close()
        cleanupDir(dir)
    }

    @TestCase
    func testStatsWithCacheDisabled(): Unit {
        let dir = "/tmp/badger_stats_nocache"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))
        db.updateOrThrow({ txn => txn.set(k(1), Array<Byte>(10, repeat: 1)) })
        db.flushMemTable()
        let _ = db.get(k(1))
        let st = db.getStats()
        @Assert(st.BlockCache.UsedBytes, 0)
        @Assert(st.BlockCache.Hits, 0)
        db.close()
        cleanupDir(dir)
    }
}
