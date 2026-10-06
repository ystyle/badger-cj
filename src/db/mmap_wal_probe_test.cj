package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import badgercj.table.*

/**
 * 诊断：mmap WAL 的跨实例可见性（进程内不 close 直接另开）。
 * 场景对应 CrashRecoveryTest.testWalRecoveryWithoutClose —— 遗留 WAL 的 replay。
 */
@Test
class MmapWalProbeTest {
    @TestCase
    func testCrossInstanceVisibility() {
        let dir = "/tmp/badger_mmap_wal_probe"
        if (exists(Path(dir))) {
            remove(Path(dir), recursive: true)
        }
        Directory.create(Path(dir), recursive: true)
        let path = dir + "/1.mem"
        let cap: Int64 = 131072

        let w1 = WAL.open(path, capacity: cap, useMmap: true)
        w1.write("k1".toArray(), ValueStruct("v1".toArray()).encode())
        w1.write("k2".toArray(), ValueStruct("v2".toArray()).encode())
        w1.flush()
        println("[probe] w1 写入 2 条完毕（未 close）")
        let lenAfterWrite = File(Path(path), Read).length
        println("[probe] 文件长度 = ${lenAfterWrite}")

        // 读写模式重开（badger 恢复遗留 WAL 走的就是这条路径）：
        // 关键回归点——open 不得清空既有内容（曾因 O_TRUNC 导致 replay 读到全 0）
        let w2 = WAL.open(path, capacity: cap, useMmap: true)
        let entries = w2.readAll()
        println("[probe] 读写模式重开后读到 ${entries.size} 条")
        @Expect(entries.size, 2)

        let w3 = WAL.openForRead(path, useMmap: true)
        let entries3 = w3.readAll()
        println("[probe] 只读模式重开后读到 ${entries3.size} 条")
        @Expect(entries3.size, 2)
    }
}
