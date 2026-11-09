package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*

// L2 流式落盘（Config.StreamingSSTable=true）端到端：写→读→重开全量可见。
@Test
class StreamingFlushTest {
    private func k(i: Int64): Array<Byte> {
        let raw = i.toString()
        let pad = 4 - raw.size
        ("sf-" + String.fromUtf8(Array<Byte>(pad, repeat: 0x30)) + raw).toArray()
    }

    @TestCase
    func testStreamingFlushRoundTrip(): Unit {
        let dir = "/tmp/badger_streaming_flush"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64,
            streamingSSTable: true))
        let value = Array<Byte>(120, repeat: 0x63)
        var i: Int64 = 0
        while (i < 500) {
            let start = i
            db.updateOrThrow({ txn =>
                var j: Int64 = 0
                while (j < 50) {
                    txn.set(k(start + j), value)
                    j++
                }
            })
            i += 50
        }
        db.flushMemTable()
        var ok = true
        for (n in 0..500) {
            if (db.get(k(n)).isNone()) {
                ok = false
            }
        }
        @Assert(ok, true)
        db.close()

        let db2 = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64,
            streamingSSTable: true))
        var ok2 = true
        for (n in 0..500) {
            if (db2.get(k(n)).isNone()) {
                ok2 = false
            }
        }
        @Assert(ok2, true)
        db2.close()
        @Assert(testCountFilesWithSuffix(dir, ".sst") >= 1, true)
        cleanupDir(dir)
    }
}
