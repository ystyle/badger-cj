package badgercj.vlog

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*

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
}
