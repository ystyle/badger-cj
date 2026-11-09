package badgercj.table

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*

// L2 流式构建等价性：sink 模式（块完成即写文件）的输出必须与一次性 finish() 位级一致。
@Test
class BuilderStreamTest {
    private func key(i: Int64): Array<Byte> {
        let raw = i.toString()
        let pad = 4 - raw.size
        ("bs-" + String.fromUtf8(Array<Byte>(pad, repeat: 0x30)) + raw).toArray()
    }

    private func value(i: Int64): Array<Byte> {
        Array<Byte>(60, repeat: UInt8(i % 251))
    }

    @TestCase
    func testStreamingMatchesInMemoryBytes(): Unit {
        let dir = "/tmp/badger_builder_stream"
        if (exists(Path(dir))) { remove(Path(dir), recursive: true) }
        Directory.create(dir)
        let path = dir + "/stream.sst"

        // 1) 普通构建
        let normalBuilder = TableBuilder(blockSize: 1024)
        for (i in 0..500) {
            normalBuilder.add(key(i), ValueStruct(value(i), version: UInt64(i + 1)))
        }
        let normal = normalBuilder.finish()
        @Assert(normal.size > 0, true)

        // 2) 流式构建：块完成即写文件
        let f = File(Path(path), ReadWrite)
        let streamBuilder = TableBuilder(blockSize: 1024, sink: { data => f.write(data) })
        for (i in 0..500) {
            streamBuilder.add(key(i), ValueStruct(value(i), version: UInt64(i + 1)))
        }
        let rest = streamBuilder.finish()
        f.close()
        @Assert(rest.size, 0)

        // 3) 位级等价
        let streamed = File.readFrom(Path(path))
        @Assert(streamed.size, normal.size)
        var same = true
        var firstDiff: Int64 = -1
        for (i in 0..normal.size) {
            if (streamed[i] != normal[i]) {
                same = false
                firstDiff = i
                break
            }
        }
        println("[builder-stream] size=" + normal.size.toString() + " same=" + same.toString() + " firstDiff=" + firstDiff.toString())
        @Assert(same, true)

        // 4) 流式产物可被 Table 正常读回
        let table = Table(1, streamed)
        @Assert(table.keyCount, UInt32(500))
        @Assert(table.get(key(123)).isSome(), true)
        if (exists(Path(dir))) { remove(Path(dir), recursive: true) }
    }
}
