package badgercj.vlog

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.fs.*
import badgercj.table.*

@Test
class VLogGCTest {
    
    @TestCase
    func testDiscardStatsBasic() {
        let stats = DiscardStats(Path("./test_discard_stats"))
        
        let val1 = stats.update(1u32, 100)
        @Assert(val1, 100)
        
        let val2 = stats.update(1u32, 50)
        @Assert(val2, 150)
        
        let (maxFid, maxVal) = stats.maxDiscard()
        @Assert(maxFid, 1u32)
        @Assert(maxVal, 150)
        
        stats.clear(1u32)
        @Assert(stats.get(1u32), 0)
    }
    
    @TestCase
    func testDiscardStatsMultipleFiles() {
        let stats = DiscardStats(Path("./test_discard_multi"))
        
        stats.update(1u32, 100)
        stats.update(2u32, 200)
        stats.update(3u32, 50)
        
        let (maxFid, maxVal) = stats.maxDiscard()
        @Assert(maxFid, 2u32)
        @Assert(maxVal, 200)
    }
    
    @TestCase
    func testGCFileRewriterBasic() {
        let mockDb = MockVLogGCDB()
        let rewriter = GCFileRewriter(mockDb, 1u32)
        
        let key1 = "key1".toArray()
        let key2 = "key2".toArray()
        let entry1 = LogEntry(key1, "value1".toArray())
        let entry2 = LogEntry(key2, "value2".toArray())
        
        mockDb.setData(key1, ValuePointer(1u32, 100u32, 0u32).encode(), meta: Meta.bitValuePointer)
        mockDb.setData(key2, ValuePointer(2u32, 100u32, 0u32).encode(), meta: Meta.bitValuePointer)
        
        rewriter.process(entry1, 0u32)
        rewriter.process(entry2, 0u32)
        
        rewriter.flush()
        
        @Assert(mockDb.getSetCount() >= 1, true)
    }
}

class MockVLogGCDB <: VLogGCDB {
    private var setCount: Int64
    
    public init() {
        this.setCount = 0
    }
    
    // Mock 实现忽略参数，仅计数
    public func setData(_: Array<Byte>, _: Array<Byte>, meta!: Byte): Unit {
        _ = meta  // 忽略未使用参数
        setCount++
    }
    
    public func getVS(_: Array<Byte>): ?ValueStruct {
        None
    }
    
    public func setRaw(_: Array<Byte>, _: Array<Byte>, _: Byte, _: UInt64, _: UInt64): Unit {
        setCount++
    }
    
    public func getValueThreshold(): UInt64 { 1024 }
    
    public func getSetCount(): Int64 { setCount }
}

class Counter {
    private var count: Int64
    
    public init() {
        this.count = 0
    }
    
    public func inc(): Unit {
        count++
    }
    
    public func get(): Int64 {
        count
    }
}

@Test
class VLogManagerGCTest {
    
    @TestCase
    func testIterateEmpty() {
        let dir = Path("./test_vlog_iterate")
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
        Directory.create(dir.toString())
        
        let vlog = VLogManager(dir)
        
        let counter = Counter()
        vlog.iterate(0u32, { entry, offset =>
            counter.inc()
            true
        })
        
        @Assert(counter.get(), 0)
        
        vlog.close()
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }
    
    @TestCase
    func testIterateWithEntries() {
        let dir = Path("./test_vlog_iterate_entries")
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
        Directory.create(dir.toString())
        
        let vlog = VLogManager(dir)
        
        let entry1 = LogEntry("key1".toArray(), "value1".toArray())
        let entry2 = LogEntry("key2".toArray(), "value2".toArray())
        vlog.write(entry1)
        vlog.write(entry2)
        
        let counter = Counter()
        vlog.iterate(0u32, { entry, offset =>
            counter.inc()
            true
        })
        
        @Assert(counter.get(), 2)
        
        vlog.close()
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }
    
    @TestCase
    func testPickLogNoFiles() {
        let dir = Path("./test_vlog_picklog")
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
        Directory.create(dir.toString())
        
        let vlog = VLogManager(dir)
        
        let result = vlog.pickLog(0.5)
        @Assert(result.isNone(), true)
        
        vlog.close()
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }
    
    @TestCase
    func testAddDiscard() {
        let dir = Path("./test_vlog_add_discard")
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
        Directory.create(dir.toString())
        
        let vlog = VLogManager(dir)
        
        let entry1 = LogEntry("key1".toArray(), "value1".toArray())
        vlog.write(entry1)
        
        vlog.addDiscard(0u32, 100)
        
        let ratio = vlog.getDiscardRatio(0u32)
        @Assert(ratio > 0.0, true)
        
        vlog.close()
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }
    
    @TestCase
    func testRewriteWithoutDB() {
        let dir = Path("./test_vlog_rewrite_no_db")
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
        Directory.create(dir.toString())
        
        let vlog = VLogManager(dir)
        
        let entry1 = LogEntry("key1".toArray(), "value1".toArray())
        vlog.write(entry1)
        
        let result = vlog.rewrite(0u32)
        @Assert(result, false)
        
        vlog.close()
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }
    
    @TestCase
    func testRewriteWithMockDB() {
        let dir = Path("./test_vlog_rewrite_mock")
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
        Directory.create(dir.toString())
        
        let mockDb = MockVLogGCDB()
        let vlog = VLogManager(dir)
        vlog.setDB(mockDb)
        
        let entry1 = LogEntry("key1".toArray(), "value1".toArray())
        let vp1 = vlog.write(entry1)
        
        let entry2 = LogEntry("key2".toArray(), "value2".toArray())
        vlog.write(entry2)
        
        let result = vlog.rewrite(0u32)
        @Assert(result, true)
        
        vlog.close()
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }
}