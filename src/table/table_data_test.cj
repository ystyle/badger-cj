package badgercj.table

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*

/**
 * TableData 抽象的双模式等价回归（SSTable 读按需化 阶段 B）。
 *
 * 同一份 .sst 分别经 MemoryTableData（内存）与 MmapTableData（只读映射）打开，
 * 元信息与逐 key 读取必须完全一致——这是「表数据移出 GC 堆」不改变读语义的最低保证。
 */
@Test
class TableDataTest {
    private func cleanup(dir: String): Unit {
        let p = Path(dir)
        if (exists(p)) {
            remove(p, recursive: true)
        }
    }

    @TestCase
    func testMmapAndMemoryTableDataEquivalent(): Unit {
        let dir = "./test_table_data_equiv"
        cleanup(dir)
        Directory.create(dir)
        let path = "${dir}/1.sst"

        // 构建一张含 64 个 key 的表并落盘
        let builder = TableBuilder(blockSize: 1024)
        let keys = ArrayList<Array<Byte>>()
        for (i in 0..64) {
            let key = Array<Byte>(8, { j => UInt8((i + j) % 256) })
            keys.add(key)
            let vs = ValueStruct(Array<Byte>(32, { j => UInt8((i * 3 + j) % 256) }), version: 1)
            builder.add(key, vs)
        }
        let data = builder.finish()
        @Expect(data.size > 0, true)

        let f = File(Path(path), ReadWrite)
        f.write(data)
        f.close()

        // 两种数据源打开同一张表
        let tMem = Table(1, tableData: MemoryTableData(data))
        let tMmap = Table(1, tableData: MmapTableData(path))

        // 元信息一致（索引解析走的是"按需读尾部"，必须与全量解析等价）
        @Expect(tMmap.keyCount, tMem.keyCount)
        @Expect(tMmap.maxVersion, tMem.maxVersion)
        @Expect(tMmap.numBlocks(), tMem.numBlocks())
        @Expect(tMmap.onDiskSize(), tMem.onDiskSize())
        @Expect(tMmap.smallest == tMem.smallest, true)
        @Expect(tMmap.biggest == tMem.biggest, true)

        // 逐 key 内容一致
        for (key in keys) {
            let a = tMem.get(key).getOrThrow()
            let b = tMmap.get(key).getOrThrow()
            @Expect(b == a, true)
        }

        // 块迭代器也一致（走 readBlock → 映射读）
        for (i in 0..tMem.numBlocks()) {
            let itMem = tMem.blockIterator(i)
            let itMmap = tMmap.blockIterator(i)
            @Expect(itMmap.isValid(), itMem.isValid())
        }

        tMmap.close()
        cleanup(dir)
    }

    @TestCase
    func testMmapTableDataReadsIndexOnDemand(): Unit {
        // 索引在文件尾部：按需解析只读末尾若干字节，不依赖全量数据。
        let dir = "./test_table_data_ondemand"
        cleanup(dir)
        Directory.create(dir)
        let path = "${dir}/2.sst"

        let builder = TableBuilder(blockSize: 1024)
        for (i in 0..32) {
            let key = Array<Byte>(8, { j => UInt8((i + j * 2) % 256) })
            let _ = builder.add(key, ValueStruct(Array<Byte>(16, repeat: UInt8(i % 256)), version: 1))
        }
        let data = builder.finish()
        let f = File(Path(path), ReadWrite)
        f.write(data)
        f.close()

        let tMmap = Table(2, tableData: MmapTableData(path))
        @Expect(tMmap.numBlocks() > 0, true)
        tMmap.close()
        cleanup(dir)
    }
}
