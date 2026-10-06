package badgercj.db

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 阶段 4 收口：mmap 段的「稀疏预分配 → 关闭时截断回收」必须成对成立。
 *
 * 只断言"关闭后文件很小"是不够的——若预分配从未发生，测试会空过；
 * 因此这里先断言**打开期间**文件确实被预分配到容量上限，再断言关闭后缩回有效长度。
 * 否则小库会在磁盘上留下 GB 级空洞。
 */
@Test
class PreallocReclaimTest {
    private func cleanup(dir: String): Unit {
        let p = Path(dir)
        if (exists(p)) {
            remove(p, recursive: true)
        }
    }

    /** 统计目录下指定后缀文件的总长度 */
    private func totalLen(dir: String, suffix: String): Int64 {
        var total: Int64 = 0
        for (e in Directory.readFrom(Path(dir))) {
            if (e.name.endsWith(suffix)) {
                let f = File(Path("${dir}/${e.name}"), Read)
                total += f.length
                f.close()
            }
        }
        return total
    }

    @TestCase
    func testPreallocThenReclaimOnClose(): Unit {
        let dir = "./test_prealloc_reclaim"
        cleanup(dir)
        let memTableSize: UInt64 = 64 * 1024u64
        let opt = Config(dir: dir, memTableSize: memTableSize,
            valueThreshold: 64u64, mmapWAL: true, mmapVLog: true)
        let db = Badger.open(opt)

        let bigValue = Array<Byte>(512, repeat: 9u8)
        for (i in 0..8) {
            let _ = db.update({ t => t.set("key${i}".toArray(), bigValue) })
        }

        // 打开期间：WAL 与 VLog 段都按各自容量稀疏预分配（WAL=2×memTableSize、VLog=maxFileSize）
        let walOpen = totalLen(dir, ".mem")
        let vlogOpen = totalLen(dir, ".vlog")
        @Expect(walOpen >= Int64(memTableSize), true)
        @Expect(vlogOpen >= Int64(memTableSize), true)

        db.close()

        // 关闭后：各段截断回到实际有效长度，不留预分配空洞
        let walClosed = totalLen(dir, ".mem")
        let vlogClosed = totalLen(dir, ".vlog")
        @Expect(walClosed < Int64(memTableSize), true)
        @Expect(vlogClosed < Int64(memTableSize), true)

        // 数据仍可恢复（重新打开读回）
        let db2 = Badger.open(opt)
        @Expect(db2.get("key7".toArray()).getOrThrow().value, bigValue)
        db2.close()
        cleanup(dir)
    }
}
