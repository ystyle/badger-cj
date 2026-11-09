package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*

// L2 流式落盘（Config.StreamingSSTable=true）端到端：flush 与 compaction 两条建表路径。
@Test
class StreamingFlushTest {
    private func k(i: Int64): Array<Byte> {
        let raw = i.toString()
        let pad = 4 - raw.size
        ("sf-" + String.fromUtf8(Array<Byte>(pad, repeat: 0x30)) + raw).toArray()
    }

    private func writeKeys(db: Badger, count: Int64, batch: Int64): Unit {
        let value = Array<Byte>(120, repeat: 0x63)
        var i: Int64 = 0
        while (i < count) {
            let start = i
            db.updateOrThrow({ txn =>
                var j: Int64 = 0
                while (j < batch) {
                    txn.set(k(start + j), value)
                    j++
                }
            })
            i += batch
        }
    }

    private func readAll(db: Badger, count: Int64): Bool {
        var ok = true
        for (n in 0..count) {
            if (db.get(k(n)).isNone()) {
                ok = false
            }
        }
        ok
    }

    @TestCase
    func testStreamingFlushRoundTrip(): Unit {
        let dir = "/tmp/badger_streaming_flush"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64, streamingSSTable: true))
        writeKeys(db, 500, 50)
        db.flushMemTable()
        @Assert(readAll(db, 500), true)
        db.close()
        let db2 = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64, streamingSSTable: true))
        @Assert(readAll(db2, 500), true)
        db2.close()
        @Assert(testCountFilesWithSuffix(dir, ".sst") >= 1, true)
        cleanupDir(dir)
    }

    @TestCase
    func testStreamingCompactionRoundTrip(): Unit {
        let dir = "/tmp/badger_streaming_compact"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64,
            numLevelZeroTables: 1, streamingSSTable: true))
        writeKeys(db, 600, 50)
        db.flushMemTable()
        db.compact()
        db.flushMemTable()
        db.compact()
        @Assert(readAll(db, 600), true)
        let tables = db.tables().size
        let files = testCountFilesWithSuffix(dir, ".sst")
        @Assert(files, Int64(tables))
        db.close()
        let db2 = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64, streamingSSTable: true))
        @Assert(readAll(db2, 600), true)
        db2.close()
        cleanupDir(dir)
    }
}
