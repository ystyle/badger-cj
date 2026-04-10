package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*

@Test
class P1ConfigWithTest {
    
    @TestCase
    func testWithDir() {
        let config = Config().withDir("/tmp/testdb")
        @Assert(config.Dir == "/tmp/testdb")
    }
    
    @TestCase
    func testWithMemTableSize() {
        let config = Config().withMemTableSize(128 * 1024 * 1024u64)
        @Assert(config.MemTableSize == 128 * 1024 * 1024u64)
    }
    
    @TestCase
    func testWithValueThreshold() {
        let config = Config().withValueThreshold(2 * 1024 * 1024u64)
        @Assert(config.ValueThreshold == 2 * 1024 * 1024u64)
    }
    
    @TestCase
    func testWithDisableWAL() {
        let config = Config().withDisableWAL(true)
        @Assert(config.DisableWAL == true)
    }
    
    @TestCase
    func testWithDetectConflicts() {
        let config = Config().withDetectConflicts(false)
        @Assert(config.DetectConflicts == false)
    }
    
    @TestCase
    func testChainedWithMethods() {
        let config = Config()
            .withDir("/tmp/testdb")
            .withValueThreshold(512 * 1024u64)
            .withDisableWAL(true)
        
        @Assert(config.Dir == "/tmp/testdb")
        @Assert(config.ValueThreshold == 512 * 1024u64)
        @Assert(config.DisableWAL == true)
    }
}

@Test
class P1DBInfoApiTest {
    
    @TestCase
    func testIsClosed() {
        let dir = "/tmp/badger_p1_isClosed_test"
        cleanupDir(dir)
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        @Assert(db.isClosed() == false)
        
        db.close()
        @Assert(db.isClosed() == true)
        
        cleanupDir(dir)
    }
    
    @TestCase
    func testSize() {
        let dir = "/tmp/badger_p1_size_test"
        cleanupDir(dir)
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        let txn = db.newTransaction(update: true)
        txn.set([0x61, 0x62], [0x01, 0x02, 0x03, 0x04, 0x05])
        txn.commit()
        
        let size = db.size()
        @Assert(size.LSM >= 0)
        @Assert(size.VLog >= 0)
        
        db.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testTables() {
        let dir = "/tmp/badger_p1_tables_test"
        cleanupDir(dir)
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        let tables = db.tables()
        @Assert(tables.size >= 0)
        
        db.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testLevels() {
        let dir = "/tmp/badger_p1_levels_test"
        cleanupDir(dir)
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        let levels = db.levels()
        @Assert(levels.size == 7)
        
        for (info in levels) {
            @Assert(info.Level >= 0 && info.Level < 7)
            @Assert(info.NumTables >= 0)
            @Assert(info.Size >= 0)
        }
        
        db.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testSync() {
        let dir = "/tmp/badger_p1_sync_test"
        cleanupDir(dir)
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        db.sync()
        
        db.close()
        cleanupDir(dir)
    }
}

@Test
class P1ValidForPrefixTest {
    
    @TestCase
    func testValidForPrefixBasic() {
        let dir = "/tmp/badger_p1_vfp_test"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        db.updateOrThrow({ txn =>
            txn.set("prefix_a/key1".toArray(), "value1".toArray())
            txn.set("prefix_a/key2".toArray(), "value2".toArray())
            txn.set("other/key3".toArray(), "value3".toArray())
        })
        
        let readTxn = db.newTransaction(update: false)
        let iter = readTxn.newIterator()
        
        let keys = ArrayList<String>()
        iter.seek("prefix_a/".toArray())
        while (iter.validForPrefix("prefix_a/".toArray())) {
            let item = iter.item()
            keys.add(bytesToString(item.key))
            iter.next()
        }
        
        iter.close()
        readTxn.discard()
        db.close()
        cleanupDir(dir)
        
        @Assert(keys.size, 2)
        if (keys.size > 0) {
            @Assert(keys[0], "prefix_a/key1")
        }
        if (keys.size > 1) {
            @Assert(keys[1], "prefix_a/key2")
        }
    }
    
    @TestCase
    func testValidForPrefixNoMatch() {
        let dir = "/tmp/badger_p1_vfp_nomatch_test"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        
        db.updateOrThrow({ txn =>
            txn.set("abc".toArray(), "value".toArray())
        })
        
        let readTxn = db.newTransaction(update: false)
        let iter = readTxn.newIterator()
        
        let keys = ArrayList<String>()
        iter.seek("xyz".toArray())
        while (iter.validForPrefix("xyz".toArray())) {
            let item = iter.item()
            keys.add(bytesToString(item.key))
            iter.next()
        }
        
        iter.close()
        readTxn.discard()
        db.close()
        cleanupDir(dir)
        
        @Assert(keys.size, 0)
    }
}