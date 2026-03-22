package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.fs.*
import badgercj.table.CompressionType

@Test
class CompressionTest {
    
    @TestCase
    func testSnappyCompression(): Unit {
        let opt = Config(dir: "/tmp/badger_compression_test", memTableSize: 64 * 1024u64)
            .withCompression(CompressionType.Snappy)
        let db = Badger.open(opt)
        
        // 写入可压缩数据
        for (i in 0..100) {
            let key = "key${i}".toArray()
            let value = Array<Byte>(1000, repeat: 0x41)
            db.update({ txn =>
                txn.set(key, value)
            })
        }
        
        // 验证数据
        for (i in 0..100) {
            if (let Some(vs) <- db.get("key${i}".toArray())) {
                @Assert(vs.value.size == 1000)
            } else {
                db.close()
                @Fail("Should find key${i}")
            }
        }
        
        db.close()
        cleanupDir("/tmp/badger_compression_test")
    }
    
    @TestCase
    func testInMemoryWithCompression(): Unit {
        let opt = Config(inMemory: true, memTableSize: 64 * 1024u64)
            .withCompression(CompressionType.Snappy)
        let db = Badger.open(opt)
        
        db.update({ txn =>
            txn.set("key1".toArray(), Array<Byte>(100, repeat: 0x43))
            txn.set("key2".toArray(), Array<Byte>(100, repeat: 0x43))
        })
        
        @Assert(db.get("key1".toArray()).isSome())
        @Assert(db.get("key2".toArray()).isSome())
        
        db.close()
    }
}