package badgercj.db

import std.time.*
import badgercj.table.Meta

@Test
class EntryTest {
    @TestCase
    func testBasicEntry() {
        let e = Entry("key".toArray(), "value".toArray())
        @Assert(e.key == "key".toArray())
        @Assert(e.value == "value".toArray())
        @Assert(e.userMeta == 0)
        @Assert(e.expiresAt == 0u64)
    }
    
    @TestCase
    func testWithMeta() {
        let e = Entry("key".toArray(), "value".toArray())
            .withMeta(0x01)
        @Assert(e.userMeta == 0x01)
    }
    
    @TestCase
    func testWithTTL() {
        let e = Entry("key".toArray(), "value".toArray())
            .withTTL(Duration.hour * 24)
        @Assert(e.expiresAt > 0u64)
    }
    
    @TestCase
    func testWithDiscard() {
        let e = Entry("key".toArray(), "value".toArray())
            .withDiscard()
        @Assert((e.userMeta & Meta.bitDiscardEarlierVersions) != 0)
    }
    
    @TestCase
    func testChainedWith() {
        let e = Entry("key".toArray(), "value".toArray())
            .withMeta(0x01)
            .withTTL(Duration.hour)
        @Assert(e.userMeta == 0x01)
        @Assert(e.expiresAt > 0u64)
    }
    
    @TestCase
    func testStaticNew() {
        let e = Entry.new("key".toArray(), "value".toArray())
        @Assert(e.key == "key".toArray())
        @Assert(e.value == "value".toArray())
        @Assert(!e.isDelete())
    }
    
    @TestCase
    func testStaticDelete() {
        let e = Entry.delete("key".toArray())
        @Assert(e.key == "key".toArray())
        @Assert(e.isDelete())
    }
}