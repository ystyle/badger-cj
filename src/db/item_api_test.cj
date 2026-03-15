package badgercj.db

import std.time.*
import badgercj.table.Meta

@Test
class ItemApiTest {
    @TestCase
    func testKeyCopy() {
        let item = Item("key".toArray(), "value".toArray())
        let copy = item.keyCopy()
        @Assert(copy == "key".toArray())
    }
    
    @TestCase
    func testValueCopy() {
        let item = Item("key".toArray(), "value".toArray())
        let copy = item.valueCopy()
        @Assert(copy == "value".toArray())
    }
    
    @TestCase
    func testKeySize() {
        let item = Item("hello".toArray(), "world".toArray())
        @Assert(item.keySize() == 5)
    }
    
    @TestCase
    func testValueSize() {
        let item = Item("hi".toArray(), "world".toArray())
        @Assert(item.valueSize() == 5)
    }
    
    @TestCase
    func testDiscardEarlierVersionsTrue() {
        let item = Item("key".toArray(), "value".toArray(), meta: Meta.bitDiscardEarlierVersions)
        @Assert(item.discardEarlierVersions())
    }
    
    @TestCase
    func testDiscardEarlierVersionsFalse() {
        let item = Item("key".toArray(), "value".toArray(), meta: 0)
        @Assert(!item.discardEarlierVersions())
    }
    
    @TestCase
    func testIsDeletedOrExpiredDeleted() {
        let item = Item("key".toArray(), "value".toArray(), meta: Meta.bitDelete)
        @Assert(item.isDeletedOrExpired())
    }
    
    @TestCase
    func testIsDeletedOrExpiredNotExpired() {
        let futureTime = UInt64(DateTime.now().toUnixTimeStamp().toSeconds()) + 10000u64
        let item = Item("key".toArray(), "value".toArray(), expiresAt: futureTime)
        @Assert(!item.isDeletedOrExpired())
    }
    
    @TestCase
    func testEstimateSize() {
        let item = Item("abc".toArray(), "defg".toArray())
        @Assert(item.estimateSize() == 7 + 16)
    }
}