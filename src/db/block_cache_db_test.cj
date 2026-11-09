package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*

// Block Cache 端到端：开启后热点 block 命中、读结果正确；关闭时行为与 2.0.1 一致。
@Test
class BlockCacheDbTest {
    private func k(i: Int64): Array<Byte> {
        let raw = i.toString()
        let pad = 4 - raw.size
        ("bc-" + String.fromUtf8(Array<Byte>(pad, repeat: 0x30)) + raw).toArray()
    }

    @TestCase
    func testCacheFillsAndReadsCorrectly(): Unit {
        let dir = "/tmp/badger_block_cache_db"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))
        let value = Array<Byte>(200, repeat: 0x31)
        for (i in 0..200) {
            let key = k(i)
            db.updateOrThrow({ txn => txn.set(key, value) })
        }
        db.flushMemTable()
        db.close()

        let db2 = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64, blockCacheSizeMB: 1))
        var ok = true
        for (i in 0..200) {
            if (db2.get(k(i)).isNone()) {
                ok = false
            }
        }
        @Assert(ok, true)
        // 第二遍应命中缓存
        for (i in 0..200) {
            if (db2.get(k(i)).isNone()) {
                ok = false
            }
        }
        @Assert(ok, true)
        @Assert(db2.blockCacheUsedBytes() > 0, true)
        db2.close()
        cleanupDir(dir)
    }

    @TestCase
    func testCacheDisabledByDefault(): Unit {
        let dir = "/tmp/badger_block_cache_off"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))
        db.updateOrThrow({ txn => txn.set(k(1), Array<Byte>(10, repeat: 1)) })
        db.flushMemTable()
        @Assert(db.blockCacheUsedBytes(), 0)
        @Assert(db.get(k(1)).isSome(), true)
        @Assert(db.blockCacheUsedBytes(), 0)
        db.close()
        cleanupDir(dir)
    }
}
