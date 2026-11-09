package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.fs.*

// WAL.writeBatch：整批一次映射写；批内按条目边界跨段切分。replay（readAll）必须逐条还原。
@Test
class WalBatchTest {
    @TestCase
    func testWriteBatchAcrossSegments(): Unit {
        let dir = "/tmp/badger_wal_batch_segments"
        cleanupDir(dir)
        Directory.create(dir)
        let path = "${dir}/1.mem"
        // 段容量 256B：每条 ~29B，一批 40 条必然跨多段
        let wal = WAL.open(path, capacity: 256, useMmap: true)
        let keys = ArrayList<Array<Byte>>()
        let values = ArrayList<Array<Byte>>()
        for (i in 0..40) {
            keys.add("k-${i}".toArray())
            values.add("v-${i}".toArray())
        }
        wal.writeBatch(keys, values)
        wal.sync()
        wal.close()

        // 段数 > 1（<fid>.mem + <fid>.mem.N）
        var segments: Int64 = 0
        for (e in Directory.readFrom(Path(dir))) {
            if (!e.isDirectory() && e.name.startsWith("1.mem")) {
                segments++
            }
        }
        @Assert(segments > 1, true)

        // 重开（readAll）逐条还原，顺序与内容一致
        let reader = WAL.openForRead(path, useMmap: true)
        let entries = reader.readAll()
        reader.close()
        @Assert(entries.size, 40)
        for (i in 0..40) {
            @Assert(String.fromUtf8(entries[i].key), "k-${i}")
            @Assert(String.fromUtf8(entries[i].value), "v-${i}")
        }
        cleanupDir(dir)
    }

    @TestCase
    func testBatchInterleavedWithSingleWrite(): Unit {
        let dir = "/tmp/badger_wal_batch_interleave"
        cleanupDir(dir)
        Directory.create(dir)
        let path = "${dir}/1.mem"
        let wal = WAL.open(path, capacity: 4096, useMmap: true)
        wal.write("s-0".toArray(), "v0".toArray())
        let keys = ArrayList<Array<Byte>>()
        let values = ArrayList<Array<Byte>>()
        for (i in 0..5) {
            keys.add("b-${i}".toArray())
            values.add("w-${i}".toArray())
        }
        wal.writeBatch(keys, values)
        wal.write("s-1".toArray(), "v1".toArray())
        wal.sync()
        wal.close()

        let reader = WAL.openForRead(path, useMmap: true)
        let entries = reader.readAll()
        reader.close()
        @Assert(entries.size, 7)
        @Assert(String.fromUtf8(entries[0].key), "s-0")
        @Assert(String.fromUtf8(entries[1].key), "b-0")
        @Assert(String.fromUtf8(entries[6].key), "s-1")
        cleanupDir(dir)
    }
}
