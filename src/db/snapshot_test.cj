package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*

@Test
class SnapshotTest {
    
    @TestCase
    func testSnapshotBasic() {
        let dir = "/tmp/snapshot_test1"
        cleanupSnapshotDir(dir)
        let db = Badger.open(Config(dir: dir))
        
        db.update({ txn =>
            txn.set("key1".toArray(), "value1".toArray())
            txn.set("key2".toArray(), "value2".toArray())
        })
        
        let snap = db.newSnapshot()
        
        let val1 = snap.get("key1".toArray())
        @Assert(val1.isSome())
        if (let Some(v) <- val1) {
            @Assert(v.value, "value1".toArray())
        }
        
        db.update({ txn => txn.set("key3".toArray(), "value3".toArray()) })
        
        let val3 = snap.get("key3".toArray())
        @Assert(val3.isNone())
        
        snap.discard()
        db.close()
        cleanupSnapshotDir(dir)
    }
    
    @TestCase
    func testSnapshotIterator() {
        let dir = "/tmp/snapshot_test2"
        cleanupSnapshotDir(dir)
        let db = Badger.open(Config(dir: dir))
        
        db.update({ txn =>
            txn.set("key1".toArray(), "value1".toArray())
            txn.set("key2".toArray(), "value2".toArray())
        })
        
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
        
        db.update({ txn => txn.set("key3".toArray(), "value3".toArray()) })
        
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
        cleanupSnapshotDir(dir)
    }
}

func cleanupSnapshotDir(path: String): Unit {
    if (exists(Path(path))) {
        remove(Path(path), recursive: true)
    }
}
