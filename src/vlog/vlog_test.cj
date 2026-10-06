package badgercj.vlog

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*
import badgercj.table.*

@Test
class LogEntryTest {
    @TestCase
    func testEncodeDecode() {
        let key: Array<Byte> = [1, 2, 3]
        let value: Array<Byte> = [10, 20, 30]
        let entry = LogEntry(key, value)
        
        let encoded = entry.encode()
        @Assert(encoded.size > 0, true)
        
        let (decoded, _) = LogEntry.decode(encoded, 0)
        @Assert(decoded.key.size, 3)
        @Assert(decoded.value.size, 3)
    }
    
    @TestCase
    func testEncodeDecodeWithMeta() {
        let entry = LogEntry([1u8], [2u8], meta: 0x01)
        let encoded = entry.encode()
        
        let (decoded, _) = LogEntry.decode(encoded, 0)
        @Assert(decoded.meta, 0x01)
    }
    
    @TestCase
    func testChecksum() {
        let entry1 = LogEntry([1u8], [2u8])
        let entry2 = LogEntry([1u8], [3u8])
        
        let encoded1 = entry1.encode()
        let encoded2 = entry2.encode()
        
        @Assert(encoded1.size != encoded2.size || encoded1 != encoded2, true)
    }
    
    @TestCase
    func testLargeEntry() {
        let key = Array<Byte>(100, {i => UInt8(i % 256)})
        let value = Array<Byte>(1000, {i => UInt8(i % 256)})
        let entry = LogEntry(key, value)
        
        let encoded = entry.encode()
        @Assert(encoded.size > 1100, true)
        
        let (decoded, _) = LogEntry.decode(encoded, 0)
        @Assert(decoded.key.size, 100)
        @Assert(decoded.value.size, 1000)
    }
}

@Test
class VLogManagerTest {
    @TestCase
    func testVLogWriteRead() {
        let dir = Path("./test_vlog_write_read")
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
        Directory.create(dir.toString())
        
        let vlog = VLogManager(dir)
        
        let entry1 = LogEntry("key1".toArray(), "value1".toArray())
        let vp1 = vlog.write(entry1)
        
        @Assert(vp1.fid, 0u32)
        @Assert(vlog.size() > 0, true)
        
        let readEntry = vlog.read(vp1)
        @Assert(readEntry.key.toArray(), "key1".toArray())
        @Assert(readEntry.value.toArray(), "value1".toArray())
        
        vlog.close()
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }
    
    @TestCase
    func testVLogMultipleWrites() {
        let dir = Path("./test_vlog_multi")
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
        Directory.create(dir.toString())
        
        let vlog = VLogManager(dir)
        
        for (i in 0..10) {
            let key = "key${i}".toArray()
            let value = "value${i}".toArray()
            let entry = LogEntry(key, value)
            let vp = vlog.write(entry)
            @Assert(vp.fid, 0u32)
        }
        
        @Assert(vlog.size() > 0, true)
        
        vlog.close()
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }
    
    @TestCase
    func testVLogMmapPreallocation() {
        // 阶段 2：VLog 段改 mmap 后按 maxFileSize 稀疏预分配。
        // 物理文件大小 == maxFileSize（稀疏，不占实际磁盘），
        // 而逻辑大小 size() 只能是实际写入量——若沿用文件长度会被撑到 maxFileSize。
        let dir = Path("./test_vlog_mmap_prealloc")
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir.toString())

        var opt = VLogOptions()
        opt.maxFileSize = 1 << 20
        let vlog = VLogManager(dir, opt: opt)
        let vp = vlog.write(LogEntry("k1".toArray(), "v1".toArray()))

        @Expect(vlog.size() < 1024, true)

        let f = File(dir.join("0.vlog"), Read)
        @Expect(UInt64(f.length), UInt64(opt.maxFileSize))
        f.close()

        @Expect(vlog.read(vp).value.toArray(), "v1".toArray())
        vlog.close()
        remove(dir, recursive: true)
    }

    @TestCase
    func testVLogReopenPreservesData() {
        // VLog 是长期文件：重开后写偏移必须恢复到已有数据的有效长度——
        // 既不能从 0 开始（会覆盖旧 value），也不能用预分配后的文件长度（会写出空洞）。
        let dir = Path("./test_vlog_reopen")
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir.toString())

        let vlog1 = VLogManager(dir)
        let vp1 = vlog1.write(LogEntry("k1".toArray(), "v1".toArray()))
        let sizeAfter1 = vlog1.size()
        vlog1.close()

        let vlog2 = VLogManager(dir)
        @Expect(vlog2.size(), sizeAfter1)

        let vp2 = vlog2.write(LogEntry("k2".toArray(), "v2".toArray()))
        @Expect(vp2.offset > vp1.offset, true)
        @Expect(vlog2.read(vp1).value.toArray(), "v1".toArray())
        @Expect(vlog2.read(vp2).value.toArray(), "v2".toArray())
        vlog2.close()
        remove(dir, recursive: true)
    }

    @TestCase
    func testVLogRotatesOnMaxFileSize() {
        // 小 maxFileSize 强制换段：每个 value 都要能按指针读回。
        let dir = Path("./test_vlog_rotate")
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir.toString())

        var opt = VLogOptions()
        opt.maxFileSize = 4096
        let vlog = VLogManager(dir, opt: opt)

        let pointers = ArrayList<ValuePointer>()
        let fids = HashSet<UInt32>()
        for (i in 0..120) {
            let vp = vlog.write(LogEntry("key${i}".toArray(), Array<Byte>(64, repeat: 7u8)))
            pointers.add(vp)
            fids.add(vp.fid)
        }
        @Expect(fids.size > 1, true)

        for (i in 0..120) {
            let e = vlog.read(pointers[i])
            @Expect(e.key == "key${i}".toArray(), true)
        }
        vlog.close()
        remove(dir, recursive: true)
    }

    @TestCase
    func testVLogGCBasic() {
        let dir = Path("./test_vlog_gc")
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
        Directory.create(dir.toString())
        
        let vlog = VLogManager(dir)
        
        let entry1 = LogEntry("key1".toArray(), "value1".toArray())
        let vp1 = vlog.write(entry1)
        
        @Assert(vp1.fid, 0u32)
        @Assert(vlog.size() > 0, true)
        
        let ratio = vlog.getDiscardRatio(0u32)
        @Assert(ratio >= 0.0, true)
        @Assert(ratio <= 1.0, true)
        
        let result = vlog.runGC(0.5)
        
        vlog.close()
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }
    
    @TestCase
    func testVLogGCNoCurrentFile() {
        let dir = Path("./test_vlog_gc_current")
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
        Directory.create(dir.toString())
        
        let vlog = VLogManager(dir)
        
        let entry1 = LogEntry("key1".toArray(), "value1".toArray())
        let _ = vlog.write(entry1)
        
        let currentFid = vlog.getCurrentFid()
        @Assert(currentFid, 0u32)
        
        let result = vlog.runGC(0.5)
        
        vlog.close()
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }
    
    @TestCase
    func testVLogGetFileCount() {
        let dir = Path("./test_vlog_filecount")
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
        Directory.create(dir.toString())
        
        let vlog = VLogManager(dir)
        
        @Assert(vlog.getFileCount(), 1)
        
        let entry1 = LogEntry("key1".toArray(), "value1".toArray())
        let _ = vlog.write(entry1)
        
        @Assert(vlog.getFileCount(), 1)
        
        vlog.close()
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }
    
    @TestCase
    func testVLogGetDiscardRatioInvalidFid() {
        let dir = Path("./test_vlog_ratio_invalid")
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
        Directory.create(dir.toString())
        
        let vlog = VLogManager(dir)
        
        let ratio = vlog.getDiscardRatio(999u32)
        @Assert(ratio, 0.0)
        
        vlog.close()
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }
    
    @TestCase
    func testVLogFileOnDisk() {
        let dir = Path("./test_vlog_file_on_disk")
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
        Directory.create(dir.toString())
        
        let vlog = VLogManager(dir)
        
        let entry = LogEntry("persist-key".toArray(), "persist-value".toArray())
        let vp = vlog.write(entry)
        
        let vlogPath = dir.join("0.vlog")
        @Assert(exists(vlogPath), true)
        
        let fileInfo = FileInfo(vlogPath)
        @Assert(fileInfo.size > 0, true)
        
        let readEntry = vlog.read(vp)
        @Assert(readEntry.key.toArray(), "persist-key".toArray())
        @Assert(readEntry.value.toArray(), "persist-value".toArray())
        
        vlog.close()
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }
    
    @TestCase
    func testVLogCloseReopenRead() {
        let dir = Path("./test_vlog_close_reopen")
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
        Directory.create(dir.toString())
        
        var savedVp: ValuePointer = ValuePointer(0, 0, 0)
        
        var vlog = VLogManager(dir)
        let entry = LogEntry("reopen-key".toArray(), "reopen-value".toArray())
        savedVp = vlog.write(entry)
        vlog.close()
        
        let vlogPath = dir.join("0.vlog")
        @Assert(exists(vlogPath), true)
        let fileInfo = FileInfo(vlogPath)
        @Assert(fileInfo.size > 0, true)
        
        vlog = VLogManager(dir)
        let readEntry = vlog.read(savedVp)
        @Assert(readEntry.key.toArray(), "reopen-key".toArray())
        @Assert(readEntry.value.toArray(), "reopen-value".toArray())
        vlog.close()
        
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }
    
    @TestCase
    func testVLogCloseReopenReadMultipleEntries() {
        let dir = Path("./test_vlog_multi_reopen")
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
        Directory.create(dir.toString())
        
        var savedVps = ArrayList<ValuePointer>()
        
        var vlog = VLogManager(dir)
        for (i in 0..10) {
            let entry = LogEntry("k${i}".toArray(), "v${i}".toArray())
            let vp = vlog.write(entry)
            savedVps.add(vp)
        }
        vlog.close()
        
        vlog = VLogManager(dir)
        for (i in 0..savedVps.size) {
            let vp = savedVps[i]
            let readEntry = vlog.read(vp)
            @Assert(readEntry.key.toArray(), "k${i}".toArray())
            @Assert(readEntry.value.toArray(), "v${i}".toArray())
        }
        vlog.close()
        
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }
}
