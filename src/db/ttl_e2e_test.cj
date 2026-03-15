package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.time.*
import std.fs.*
import std.collection.*
import badgercj.table.*

@Test
class TTLE2ETest {
    
    @TestCase
    func testExpiredKeyReturnsNone() {
        let dir = "/tmp/badger_ttl_expired_test"
        let db = Badger.open(Config(dir: dir, memTableSize: 1024 * 1024u64))
        
        let pastTime = UInt64(DateTime.now().toUnixTimeStamp().toSeconds()) - 100u64
        let entry = Entry("expired_key".toArray(), "value".toArray(), expiresAt: pastTime)
        db.batchSet(ArrayList<Entry>([entry]))
        
        let result = db.get("expired_key".toArray())
        @Assert(result.isNone())
        
        db.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testNotExpiredKeyReturnsValue() {
        let dir = "/tmp/badger_ttl_valid_test"
        let db = Badger.open(Config(dir: dir, memTableSize: 1024 * 1024u64))
        
        let futureTime = UInt64(DateTime.now().toUnixTimeStamp().toSeconds()) + 10000u64
        let entry = Entry("valid_key".toArray(), "value".toArray(), expiresAt: futureTime)
        db.batchSet(ArrayList<Entry>([entry]))
        
        if (let Some(vs) <- db.get("valid_key".toArray())) {
            @Assert(vs.value == "value".toArray())
        } else {
            @Fail("expected value but got None")
        }
        
        db.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testUserMetaPreserved() {
        let dir = "/tmp/badger_usermeta_test"
        let db = Badger.open(Config(dir: dir, memTableSize: 1024 * 1024u64))
        
        let entry = Entry("key1".toArray(), "value1".toArray(), userMeta: 0x42)
        db.batchSet(ArrayList<Entry>([entry]))
        
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator()
        iter.rewind()
        
        if (iter.valid()) {
            let item = iter.item()
            @Assert(item.userMeta == 0x42)
        } else {
            @Fail("expected item")
        }
        
        iter.close()
        txn.discard()
        db.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testWithMetaChained() {
        let dir = "/tmp/badger_withmeta_test"
        let db = Badger.open(Config(dir: dir, memTableSize: 1024 * 1024u64))
        
        let entry = Entry.new("key1".toArray(), "value1".toArray())
            .withMeta(0x55)
            .withTTL(Duration.hour * 24)
        db.batchSet(ArrayList<Entry>([entry]))
        
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator()
        iter.rewind()
        
        if (iter.valid()) {
            let item = iter.item()
            @Assert(item.userMeta == 0x55)
            @Assert(item.expiresAt > 0u64)
        } else {
            @Fail("expected item")
        }
        
        iter.close()
        txn.discard()
        db.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testWithDiscardSetsBit() {
        let entry = Entry.new("key".toArray(), "value".toArray())
            .withDiscard()
        @Assert((entry.meta & Meta.bitDiscardEarlierVersions) != 0)
    }
    
    @TestCase
    func testMixedExpiredAndValid() {
        let dir = "/tmp/badger_mixed_ttl_test"
        let db = Badger.open(Config(dir: dir, memTableSize: 1024 * 1024u64))
        
        let now = UInt64(DateTime.now().toUnixTimeStamp().toSeconds())
        let pastTime = now - 100u64
        let futureTime = now + 10000u64
        
        let entries = ArrayList<Entry>([
            Entry("expired1".toArray(), "v1".toArray(), expiresAt: pastTime),
            Entry("valid1".toArray(), "v2".toArray(), expiresAt: futureTime),
            Entry("expired2".toArray(), "v3".toArray(), expiresAt: pastTime),
            Entry("valid2".toArray(), "v4".toArray(), expiresAt: futureTime)
        ])
        db.batchSet(entries)
        
        @Assert(db.get("expired1".toArray()).isNone())
        @Assert(db.get("expired2".toArray()).isNone())
        
        if (let Some(vs) <- db.get("valid1".toArray())) {
            @Assert(vs.value == "v2".toArray())
        } else {
            @Fail("valid1 not found")
        }
        
        if (let Some(vs) <- db.get("valid2".toArray())) {
            @Assert(vs.value == "v4".toArray())
        } else {
            @Fail("valid2 not found")
        }
        
        db.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testIteratorSkipsExpired() {
        let dir = "/tmp/badger_iter_ttl_test"
        let db = Badger.open(Config(dir: dir, memTableSize: 1024 * 1024u64))
        
        let now = UInt64(DateTime.now().toUnixTimeStamp().toSeconds())
        let pastTime = now - 100u64
        let futureTime = now + 10000u64
        
        let entries = ArrayList<Entry>([
            Entry("key_a".toArray(), "expired".toArray(), expiresAt: pastTime),
            Entry("key_b".toArray(), "valid".toArray(), expiresAt: futureTime)
        ])
        db.batchSet(entries)
        
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator()
        iter.rewind()
        
        var count = 0
        while (iter.valid()) {
            let item = iter.item()
            @Assert(item.key != "key_a".toArray())  // expired should be skipped
            count++
            iter.next()
        }
        @Assert(count == 1)  // only valid key
        
        iter.close()
        txn.discard()
        db.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testCompactionFiltersExpired() {
        let dir = "/tmp/badger_compact_ttl_test"
        let db = Badger.open(Config(dir: dir, memTableSize: 1024 * 1024u64))
        
        let now = UInt64(DateTime.now().toUnixTimeStamp().toSeconds())
        let pastTime = now - 100u64
        let futureTime = now + 10000u64
        
        let entries = ArrayList<Entry>([
            Entry("expired_key".toArray(), "value".toArray(), expiresAt: pastTime),
            Entry("valid_key".toArray(), "value".toArray(), expiresAt: futureTime)
        ])
        db.batchSet(entries)
        
        db.flushMemTable()
        db.compact()
        
        @Assert(db.get("expired_key".toArray()).isNone())
        @Assert(db.get("valid_key".toArray()).isSome())
        
        db.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testDeleteEntryWithUserMeta() {
        let dir = "/tmp/badger_delete_meta_test"
        let db = Badger.open(Config(dir: dir, memTableSize: 1024 * 1024u64))
        
        let deleteEntry = Entry.delete("key_to_delete".toArray())
        db.batchSet(ArrayList<Entry>([deleteEntry]))
        
        @Assert(db.get("key_to_delete".toArray()).isNone())
        
        db.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testStaticNewAndDelete() {
        let e1 = Entry.new("k1".toArray(), "v1".toArray())
        @Assert(!e1.isDelete())
        @Assert(e1.meta == 0)
        @Assert(e1.userMeta == 0)
        
        let e2 = Entry.delete("k2".toArray())
        @Assert(e2.isDelete())
        @Assert((e2.meta & Meta.bitDelete) != 0)
    }
}