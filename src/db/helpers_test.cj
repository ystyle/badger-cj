package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.time.*
import badgercj.table.Meta
import badgercj.table.ValueStruct

@Test
class HelpersTest {
    @TestCase
    func testManifestPath() {
        let path = manifestPath("/tmp/badger")
        @Assert(path, "/tmp/badger/MANIFEST")
    }

    @TestCase
    func testWalPath() {
        let path = walPath("/tmp/badger", 1u64)
        @Assert(path, "/tmp/badger/000001.wal")

        let path2 = walPath("/tmp/badger", 123u64)
        @Assert(path2, "/tmp/badger/000123.wal")

        // 边界情况: fid = 0
        let path3 = walPath("/tmp/badger", 0u64)
        @Assert(path3, "/tmp/badger/000000.wal")

        // 边界情况: fid >= 1000000 (无补零)
        let path4 = walPath("/tmp/badger", 1000000u64)
        @Assert(path4, "/tmp/badger/1000000.wal")

        let path5 = walPath("/tmp/badger", 9999999u64)
        @Assert(path5, "/tmp/badger/9999999.wal")
    }

    @TestCase
    func testSstablePath() {
        let path = sstablePath("/tmp/badger", 1u64)
        @Assert(path, "/tmp/badger/000001.sst")

        let path2 = sstablePath("/tmp/badger", 456u64)
        @Assert(path2, "/tmp/badger/000456.sst")

        // 边界情况: fid = 0
        let path3 = sstablePath("/tmp/badger", 0u64)
        @Assert(path3, "/tmp/badger/000000.sst")

        // 边界情况: fid >= 1000000 (无补零)
        let path4 = sstablePath("/tmp/badger", 1000000u64)
        @Assert(path4, "/tmp/badger/1000000.sst")

        let path5 = sstablePath("/tmp/badger", 9999999u64)
        @Assert(path5, "/tmp/badger/9999999.sst")
    }
    
    @TestCase
    func testIsDeletedOrExpiredNotExpired() {
        @Assert(!isDeletedOrExpired(0, 0))
    }
    
    @TestCase
    func testIsDeletedOrExpiredDeleted() {
        @Assert(isDeletedOrExpired(Meta.bitDelete, 0))
    }
    
    @TestCase
    func testIsDeletedOrExpiredExpired() {
        let pastTime = UInt64(DateTime.now().toUnixTimeStamp().toSeconds()) - 100u64
        @Assert(isDeletedOrExpired(0, pastTime))
    }
    
    @TestCase
    func testIsDeletedOrExpiredNotExpiredYet() {
        let futureTime = UInt64(DateTime.now().toUnixTimeStamp().toSeconds()) + 10000u64
        @Assert(!isDeletedOrExpired(0, futureTime))
    }
    
    @TestCase
    func testDiscardEntryVersionMismatch() {
        let key = keyWithTs("test".toArray(), 100u64)
        let vs = ValueStruct("value".toArray(), version: 200u64)
        @Assert(discardEntry(key, vs))
    }
    
    @TestCase
    func testDiscardEntryNotValuePointer() {
        let key = keyWithTs("test".toArray(), 100u64)
        let vs = ValueStruct("value".toArray(), meta: 0, version: 100u64)
        @Assert(discardEntry(key, vs))
    }
}
