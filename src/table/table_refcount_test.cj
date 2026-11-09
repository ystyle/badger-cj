package badgercj.table

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*

// 表生命周期回归：引用计数归零之前，不得解映射、不得删表文件。
//
// 缺陷形态（≤ 2.1.0 的「摘除即释放」）：compaction 把旧表从 LevelHandler 摘除后
// 立刻 close 映射 + unlink 文件。但「摘除」只保证没有新读者能拿到这张表——已经在读的
// 迭代器还要读它的后续块，下一次进块就撞上已关闭的映射（运行期 `MmapFile is closed`），
// 把正常的范围扫描/链式读打成异常。
// 修复：迭代器持有表引用，最后一个引用释放时才解映射并删除已标记的文件。
@Test
class TableRefCountTest {
    private func refKey(i: Int64): Array<Byte> {
        let buf = Array<Byte>(8, repeat: 0)
        var v = UInt64(i)
        var j: Int64 = 7
        while (j >= 0) {
            buf[j] = UInt8(v & 0xFF)
            v >>= 8
            j--
        }
        buf
    }

    private func buildData(entries: Int64): Array<Byte> {
        let builder = TableBuilder(blockSize: 256)
        for (i in 0..entries) {
            builder.add(refKey(i), ValueStruct(Array<Byte>(32, repeat: UInt8(i % 256))))
        }
        builder.finish()
    }

    private func writeSST(path: String, entries: Int64): Unit {
        let data = buildData(entries)
        let f = File(Path(path), Write)
        f.write(data)
        f.close()
    }

    private func freshDir(): String {
        let dir = "/tmp/badger_table_refcount"
        if (exists(Path(dir))) {
            remove(Path(dir), recursive: true)
        }
        Directory.create(Path(dir), recursive: true)
        dir
    }

    @TestCase
    func testIteratorKeepsTableAliveAfterRemoval(): Unit {
        let dir = freshDir()
        let path = dir + "/7.sst"
        writeSST(path, 64)

        let table = Table(7, tableData: MmapTableData(path))
        let iter = table.newIterator()
        // 持有者 1 + 迭代器 1
        @Assert(table.refCount(), 2)

        // 模拟 compaction：标记文件待删 + 释放持有者引用（表已从层里摘除）
        table.markForDeletion(path)
        table.close()
        @Assert(table.refCount(), 1)
        // 迭代器可能还在读这块数据 —— 映射与文件都必须还在
        @Assert(exists(Path(path)), true)

        var count: Int64 = 0
        iter.seekFirst()
        while (iter.isValid()) {
            @Assert(iter.key().size, 8)
            count++
            iter.next()
        }
        @Assert(count, 64)

        // 最后一个引用释放：解映射 + 删文件
        iter.close()
        @Assert(table.refCount(), 0)
        @Assert(exists(Path(path)), false)
        remove(Path(dir), recursive: true)
    }

    @TestCase
    func testDoubleReleaseDoesNotGoNegative(): Unit {
        let table = Table(9, buildData(4))
        @Assert(table.refCount(), 1)
        table.close()
        @Assert(table.refCount(), 0)
        // 重复释放：恢复计数，不重复释放资源、也不打成负数
        table.close()
        @Assert(table.refCount(), 0)
    }

    @TestCase
    func testForceCloseIgnoresOutstandingReader(): Unit {
        let dir = freshDir()
        let path = dir + "/11.sst"
        writeSST(path, 8)

        let table = Table(11, tableData: MmapTableData(path))
        let iter = table.newIterator()
        @Assert(table.refCount(), 2)

        // 关库路径：不删活表文件，但必须解映射（迭代器泄漏的引用不该拖住关库）
        table.closeForce()
        @Assert(table.refCount(), 0)
        @Assert(exists(Path(path)), true)

        // 之后迭代器再 close 也不能把计数打成负数
        iter.close()
        @Assert(table.refCount(), 0)
        @Assert(exists(Path(path)), true)
        remove(Path(dir), recursive: true)
    }
}
