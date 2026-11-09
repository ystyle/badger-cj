package badgercj.vlog

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.io.*
import std.collection.ArrayList
import badgercj.table.ValuePointer

// VLog 重开恢复契约（1.6.23 修复）：
// 旧实现 VLogManager.init(dir) 无条件 create("0.vlog") 且 offset 恒 0——
// 重开后新写入的 ValuePointer.offset 指回段首（读到别的旧值 = 静默数据损坏），
// 段表 files / maxFid / currentFile 也全部丢失（可能复用已有 fid 覆盖旧段）。
// 下面用真实磁盘文件钉住：段表恢复、写偏移恢复、崩溃尾部截断、非段文件忽略、
// 段满边界与 UInt32 上限附近的 fid。

func vlogReopenCleanup(dir: Path): Unit {
    if (exists(dir)) {
        remove(dir, recursive: true)
    }
}

// 生成 size 字节的值，前 tag.size 字节写入 tag（保证各 key 的 value 互不相同）
func vlogReopenValue(tag: String, size: Int64): Array<Byte> {
    let buf = Array<Byte>(size, repeat: 0x41)
    let tagBytes = tag.toArray()
    let n = if (tagBytes.size < buf.size) {
        tagBytes.size
    } else {
        buf.size
    }
    tagBytes.copyTo(buf, 0, 0, n)
    buf
}

// 在文件末尾追加原始字节（模拟崩溃残留 / 位翻转）
func vlogReopenAppend(path: Path, bytes: Array<Byte>): Unit {
    let f = File(path, ReadWrite)
    f.seek(SeekPosition.End(0))
    f.write(bytes)
    f.close()
}

@Test
class VLogReopenSegmentTest {
    // 多段场景：重开必须恢复段表、maxFid、currentFile 与末段写偏移；
    // 新写入的 ValuePointer.offset 必须指向末段已有数据之后，旧指针与新指针都可读回原值。
    @TestCase
    func testReopenRestoresSegmentsAndWriteOffset() {
        let dir = Path("./test_vlog_reopen_segments")
        vlogReopenCleanup(dir)
        Directory.create(dir.toString())

        var opt = VLogOptions()
        opt.maxFileSize = 512u32

        var vlog = VLogManager(dir, opt: opt)
        let values = ArrayList<Array<Byte>>()
        let vps = ArrayList<ValuePointer>()
        // 18 条 ≈ 3.5 段：末段未满，重开后新写入应续写末段（而不是换段）
        for (i in 0..18) {
            let value = vlogReopenValue("val-${i}-", 100)
            values.add(value)
            vps.add(vlog.write(LogEntry("key-${i}".toArray(), value)))
        }
        let segmentCount = vlog.getFileCount()
        let lastFid = vlog.getCurrentFid()
        // 前提确认：本条用例必须真的产生多段，且末段未满
        @Assert(segmentCount > 1, true)
        let lastSegmentLen = FileInfo(dir.join("${lastFid}.vlog")).size
        @Assert(lastSegmentLen < Int64(opt.maxFileSize), true)
        vlog.close()

        vlog = VLogManager(dir, opt: opt)
        @Assert(vlog.getFileCount(), segmentCount)
        @Assert(vlog.getCurrentFid(), lastFid)
        for (i in 0..vps.size) {
            @Assert(vlog.read(vps[i]).value, values[i])
        }

        let newValue = vlogReopenValue("new-", 100)
        let newVp = vlog.write(LogEntry("new-key".toArray(), newValue))
        @Assert(newVp.fid, lastFid)
        @Assert(Int64(newVp.offset), lastSegmentLen)
        @Assert(vlog.read(newVp).value, newValue)
        // 新写入不得覆盖旧指针指向的数据
        @Assert(vlog.read(vps[0]).value, values[0])

        vlog.close()
        vlogReopenCleanup(dir)
    }

    // 段长恰好等于 maxFileSize：有效长度不能丢，也不能把下一条续写进已满的段。
    @TestCase
    func testReopenSegmentExactlyAtMaxFileSize() {
        let dir = Path("./test_vlog_reopen_exact_max")
        vlogReopenCleanup(dir)
        Directory.create(dir.toString())

        // 单条编码长度恰为 100 字节（13 固定开销 + key 2 + value 85），maxFileSize=300 → 恰好 3 条填满
        var opt = VLogOptions()
        opt.maxFileSize = 300u32

        var vlog = VLogManager(dir, opt: opt)
        let values = ArrayList<Array<Byte>>()
        let vps = ArrayList<ValuePointer>()
        for (i in 0..3) {
            let value = vlogReopenValue("f${i}", 85)
            values.add(value)
            vps.add(vlog.write(LogEntry("k${i}".toArray(), value)))
        }
        @Assert(vlog.getFileCount(), 1)
        @Assert(FileInfo(dir.join("0.vlog")).size, 300)
        vlog.close()

        vlog = VLogManager(dir, opt: opt)
        @Assert(vlog.getCurrentFid(), 0u32)
        // 段已满：重开后第一条写入必须换段
        let rotatedValue = vlogReopenValue("rot", 85)
        let rotatedVp = vlog.write(LogEntry("kr".toArray(), rotatedValue))
        @Assert(rotatedVp.fid, 1u32)
        @Assert(Int64(rotatedVp.offset), 0)
        @Assert(vlog.read(rotatedVp).value, rotatedValue)
        for (i in 0..vps.size) {
            @Assert(vlog.read(vps[i]).value, values[i])
        }

        vlog.close()
        vlogReopenCleanup(dir)
    }

    // 崩溃残留尾部（凑不出完整条目的垃圾字节）：重开截断到最后一个完整条目，之后继续读写正常。
    @TestCase
    func testReopenTruncatesCorruptTail() {
        let dir = Path("./test_vlog_reopen_corrupt_tail")
        vlogReopenCleanup(dir)
        Directory.create(dir.toString())

        var vlog = VLogManager(dir)
        let values = ArrayList<Array<Byte>>()
        for (i in 0..3) {
            let value = vlogReopenValue("tail-${i}-", 64)
            values.add(value)
            vlog.write(LogEntry("tail-${i}".toArray(), value))
        }
        let validLen = FileInfo(dir.join("0.vlog")).size
        vlog.close()

        // 12 字节垃圾：头部 8 字节解出 keyLen/valLen 均为 0xEEEEEEEE（远超文件长度），
        // 长度校验必须拦下——不能按这个长度去分配缓冲（否则 OOM）。
        let garbage: Array<Byte> = [0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE]
        vlogReopenAppend(dir.join("0.vlog"), garbage)
        @Assert(FileInfo(dir.join("0.vlog")).size, validLen + Int64(garbage.size))

        vlog = VLogManager(dir)
        @Assert(FileInfo(dir.join("0.vlog")).size, validLen)
        let newValue = vlogReopenValue("after-tail-", 64)
        let newVp = vlog.write(LogEntry("after-tail".toArray(), newValue))
        @Assert(newVp.fid, 0u32)
        @Assert(Int64(newVp.offset), validLen)
        @Assert(vlog.read(newVp).value, newValue)
        vlog.close()

        // 截断后的内容必须仍可读（第二次重开验证）
        vlog = VLogManager(dir)
        @Assert(vlog.read(newVp).value, newValue)
        vlog.close()
        vlogReopenCleanup(dir)
    }

    // 尾部是"结构完整但 CRC 不匹配"的记录：同样按崩溃尾部截断，不能当成有效数据。
    @TestCase
    func testReopenStopsAtChecksumMismatch() {
        let dir = Path("./test_vlog_reopen_bad_crc")
        vlogReopenCleanup(dir)
        Directory.create(dir.toString())

        var vlog = VLogManager(dir)
        let keepValue = vlogReopenValue("keep-", 64)
        let keepVp = vlog.write(LogEntry("keep".toArray(), keepValue))
        let validLen = FileInfo(dir.join("0.vlog")).size
        vlog.close()

        // 追加一条长度完全合法、但 key 首字节被改过（CRC 必然不匹配）的记录
        let encoded = LogEntry("AAAA".toArray(), vlogReopenValue("crc-", 40)).encode()
        let corrupt = Array<Byte>(encoded.size, repeat: 0)
        encoded.copyTo(corrupt, 0, 0, encoded.size)
        corrupt[8] = 0x5A
        vlogReopenAppend(dir.join("0.vlog"), corrupt)
        @Assert(FileInfo(dir.join("0.vlog")).size, validLen + Int64(encoded.size))

        vlog = VLogManager(dir)
        @Assert(FileInfo(dir.join("0.vlog")).size, validLen)
        @Assert(vlog.read(keepVp).value, keepValue)
        let newValue = vlogReopenValue("after-crc-", 64)
        let newVp = vlog.write(LogEntry("after-crc".toArray(), newValue))
        @Assert(Int64(newVp.offset), validLen)
        @Assert(vlog.read(newVp).value, newValue)
        vlog.close()
        vlogReopenCleanup(dir)
    }

    // 目录里夹带的非段文件 / 非法段名 / 同名目录必须忽略，不能被当成段打开。
    @TestCase
    func testReopenIgnoresNonSegmentFiles() {
        let dir = Path("./test_vlog_reopen_junk")
        vlogReopenCleanup(dir)
        Directory.create(dir.toString())

        var vlog = VLogManager(dir)
        let value = vlogReopenValue("real-", 32)
        vlog.write(LogEntry("real".toArray(), value))
        let validLen = FileInfo(dir.join("0.vlog")).size
        vlog.close()

        let one: Array<Byte> = [0x01]
        vlogReopenAppend(dir.join("notes.txt"), one)
        vlogReopenAppend(dir.join("abc.vlog"), one)
        vlogReopenAppend(dir.join(".vlog"), one)
        vlogReopenAppend(dir.join("007.vlog"), one)
        Directory.create(dir.join("9.vlog").toString())

        vlog = VLogManager(dir)
        @Assert(vlog.getFileCount(), 1)
        @Assert(vlog.getCurrentFid(), 0u32)
        let newValue = vlogReopenValue("after-junk-", 32)
        let newVp = vlog.write(LogEntry("after-junk".toArray(), newValue))
        @Assert(Int64(newVp.offset), validLen)
        @Assert(vlog.read(newVp).value, newValue)
        vlog.close()
        vlogReopenCleanup(dir)
    }

    // 空目录（首次打开）仍要创建 0.vlog，写偏移从 0 开始。
    @TestCase
    func testReopenEmptyDirCreatesFirstSegment() {
        let dir = Path("./test_vlog_reopen_empty")
        vlogReopenCleanup(dir)
        Directory.create(dir.toString())

        let vlog = VLogManager(dir)
        @Assert(vlog.getFileCount(), 1)
        @Assert(vlog.getCurrentFid(), 0u32)
        @Assert(exists(dir.join("0.vlog")), true)
        let vp = vlog.write(LogEntry("k".toArray(), "v".toArray()))
        @Assert(vp.fid, 0u32)
        @Assert(Int64(vp.offset), 0)
        vlog.close()
        vlogReopenCleanup(dir)
    }

    // 稀疏的大 fid（含空段，直到 UInt32 上限前一个）：maxFid 取最大 fid，
    // currentFile 指向它，换段到 4294967295 时不得溢出。
    @TestCase
    func testReopenWithLargeFidAndEmptySegment() {
        let dir = Path("./test_vlog_reopen_large_fid")
        vlogReopenCleanup(dir)
        Directory.create(dir.toString())

        // 单条编码 35 字节；maxFileSize=30 → 写完一条即"段满"，下一条必换段
        var opt = VLogOptions()
        opt.maxFileSize = 30u32

        var vlog = VLogManager(dir, opt: opt)
        let v0 = vlogReopenValue("fid0", 20)
        let vp0 = vlog.write(LogEntry("k0".toArray(), v0))
        vlog.close()

        let empty1 = File(dir.join("1000000.vlog"), ReadWrite)
        empty1.close()
        let empty2 = File(dir.join("4294967294.vlog"), ReadWrite)
        empty2.close()

        vlog = VLogManager(dir, opt: opt)
        @Assert(vlog.getFileCount(), 3)
        @Assert(vlog.getCurrentFid(), 4294967294u32)
        let v1 = vlogReopenValue("large", 20)
        let vp1 = vlog.write(LogEntry("k1".toArray(), v1))
        @Assert(vp1.fid, 4294967294u32)
        @Assert(Int64(vp1.offset), 0)
        @Assert(vlog.read(vp1).value, v1)
        // 换段：4294967294 → 4294967295（UInt32 上限）
        let v2 = vlogReopenValue("max", 20)
        let vp2 = vlog.write(LogEntry("k2".toArray(), v2))
        @Assert(vp2.fid, 4294967295u32)
        @Assert(vlog.read(vp2).value, v2)
        // 旧段指针仍可读
        @Assert(vlog.read(vp0).value, v0)

        vlog.close()
        vlogReopenCleanup(dir)
    }
}
