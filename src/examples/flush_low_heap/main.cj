package badgercj.examples.flush_low_heap

import std.fs.*
import std.time.*
import badgercj.db.*

// P0-2 验收：低堆（cjHeapSize=64MB）下能否完成一张大表的 flush。
// 用法: flush_low_heap [stream|plain]   （memTableSize=16MB，写约 24MB 触发一次大 flush）
main(args: Array<String>): Int64 {
    let streaming = args.size > 0 && args[0] == "stream"
    let dir = "/tmp/badger_flush_low_heap"
    if (exists(Path(dir))) {
        remove(Path(dir), recursive: true)
    }
    let db = Badger.open(Config(dir: dir, memTableSize: 16 * 1024 * 1024u64,
        numLevelZeroTables: 1000, streamingSSTable: streaming))
    let value = Array<Byte>(1024, repeat: 0x41)
    let start = MonoTime.now()
    var i: Int64 = 0
    while (i < 24000) {
        let base = i
        db.updateOrThrow({ txn =>
            var j: Int64 = 0
            while (j < 100) {
                txn.set(("k" + (base + j).toString()).toArray(), value)
                j++
            }
        })
        i += 100
    }
    db.flushMemTable()
    let ms = (MonoTime.now() - start).toNanoseconds() / 1000000
    println("LOWHEAP streaming=" + streaming.toString() + " ok=true elapsedMs=" + ms.toString())
    db.close()
    0
}
