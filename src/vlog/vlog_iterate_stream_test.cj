package badgercj.vlog

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.fs.*

// 阶段 6.2：VLog 段遍历改流式（旧实现整段 m.read 进堆）。功能与偏移必须完全等价，
// 并覆盖 file 后端与提前终止。
//
// 注：仓颉里捕获可变局部变量的 lambda 不能作为回调用（编译器要求直接调用），
// 故计数器/期望偏移放在引用类型里由回调修改。
class IterateSink {
    var count: Int64 = 0
    var nextOffset: UInt32 = 0
    var keyMismatch: String = ""
    var offsetMismatch: String = ""
}

@Test
class VLogIterateStreamTest {
    @TestCase
    func testIterateLargeSegmentInOrder(): Unit {
        let dir = "./test_vlog_iterate_stream"
        if (exists(Path(dir))) { remove(Path(dir), recursive: true) }
        Directory.create(Path(dir))
        var opt = VLogOptions()
        opt.maxFileSize = 1 << 20
        let vlog = VLogManager(Path(dir), opt: opt)

        let count: Int64 = 300
        for (i in 0..count) {
            let entry = LogEntry("key-${i}".toArray(), Array<Byte>(256, repeat: UInt8(i % 256)))
            vlog.write(entry)
        }

        let sink = IterateSink()
        vlog.iterate(0u32, { entry, offset =>
            let expectedKey = "key-${sink.count}"
            if (String.fromUtf8(entry.key) != expectedKey) {
                sink.keyMismatch = "第 ${sink.count} 条 key=${String.fromUtf8(entry.key)}，期望 ${expectedKey}"
            }
            if (offset != sink.nextOffset) {
                sink.offsetMismatch = "第 ${sink.count} 条 offset=${offset}，期望 ${sink.nextOffset}"
            }
            sink.nextOffset = offset + UInt32(13 + entry.key.size + entry.value.size)
            sink.count++
            true
        })
        @Assert(sink.keyMismatch, "")
        @Assert(sink.offsetMismatch, "")
        @Assert(sink.count, count)
        vlog.close()
        remove(Path(dir), recursive: true)
    }

    @TestCase
    func testIterateWithFileBackend(): Unit {
        let dir = "./test_vlog_iterate_file"
        if (exists(Path(dir))) { remove(Path(dir), recursive: true) }
        Directory.create(Path(dir))
        var opt = VLogOptions()
        opt.maxFileSize = 1 << 20
        opt.useMmap = false
        let vlog = VLogManager(Path(dir), opt: opt)

        for (i in 0..150) {
            vlog.write(LogEntry("k${i}".toArray(), Array<Byte>(128, repeat: 3u8)))
        }
        let sink = IterateSink()
        vlog.iterate(0u32, { entry, _ =>
            sink.count++
            true
        })
        @Assert(sink.count, 150)
        vlog.close()
        remove(Path(dir), recursive: true)
    }

    @TestCase
    func testIterateStopsOnCallbackFalse(): Unit {
        let dir = "./test_vlog_iterate_break"
        if (exists(Path(dir))) { remove(Path(dir), recursive: true) }
        Directory.create(Path(dir))
        let vlog = VLogManager(Path(dir))
        for (i in 0..50) {
            vlog.write(LogEntry("b${i}".toArray(), "v".toArray()))
        }
        let sink = IterateSink()
        vlog.iterate(0u32, { entry, _ =>
            sink.count++
            sink.count < 10
        })
        @Assert(sink.count, 10)
        vlog.close()
        remove(Path(dir), recursive: true)
    }
}
