package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*

@Test
class SnapshotTest {
    
    @TestCase
    func testSnapshotBasic() {
        let db = DB.open(DBOptions(dir: "/tmp/snapshot_test1"))
        
        db.set("key1".toArray(), "value1".toArray())
        db.set("key2".toArray(), "value2".toArray())
        
        let snap = db.newSnapshot()
        
        let val1 = snap.get("key1".toArray())
        @Assert(val1.isSome())
        if (let Some(v) <- val1) {
            @Assert(v.value, "value1".toArray())
        }
        
        db.set("key3".toArray(), "value3".toArray())
        
        let val3 = snap.get("key3".toArray())
        @Assert(val3.isNone())
        
        snap.discard()
        db.close()
        cleanupSnapshotDir("/tmp/snapshot_test1")
    }
    
    @TestCase
    func testSnapshotIterator() {
        let db = DB.open(DBOptions(dir: "/tmp/snapshot_test2"))
        
        db.set("key1".toArray(), "value1".toArray())
        db.set("key2".toArray(), "value2".toArray())
        
        let snap = db.newSnapshot()
        
        let iter = snap.newIterator()
        
        let keys = ArrayList<String>()
        iter.rewind()
        while (iter.valid()) {
            let item = iter.item()
            keys.add(bytesToString(item.key))
            iter.next()
        }
        
        @Assert(keys.size, 2)
        
        db.set("key3".toArray(), "value3".toArray())
        
        let keys2 = ArrayList<String>()
        iter.rewind()
        while (iter.valid()) {
            let item = iter.item()
            keys2.add(bytesToString(item.key))
            iter.next()
        }
        
        @Assert(keys2.size, 2)
        
        iter.close()
        snap.discard()
        db.close()
        cleanupSnapshotDir("/tmp/snapshot_test2")
    }
}

func cleanupSnapshotDir(path: String): Unit {
    try {
        remove(path)
    } catch (e: Exception) {
    }
}
