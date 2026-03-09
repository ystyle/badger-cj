package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.sync.*
import std.collection.*

@Test
class SimpleConcurrentTest {
    
    @TestCase
    func testConcurrentWritesSimple() {
        let db = DB.open(DBOptions(dir: "/tmp/badger_simple_concurrent_test1"))
        
        // 串行写入测试
        let numOperations = 100
        let futures = ArrayList<Future<Unit>>()
        
        for (i in 0..numOperations) {
            let fut = spawn {
                for (j in 0..10) {
                    let key = "simple_key${i}_${j}".toArray()
                    let value = "simple_value${i}_${j}".toArray()
                    db.set(key, value)
                }
            }
            futures.add(fut)
        }
        
        // 猉待所有线程完成
        for (fut in futures) {
            fut.get()
        }
        
        // 验证结果
        let expectedCount = numOperations * 10
        let txn = db.newTransaction(update: false)
        var count = 0
        for (i in 0..numOperations) {
            for (j in 0..10) {
                let val = txn.get("simple_key${i}_${j}".toArray())
                if (val.isSome()) {
                    count++
                }
            }
        }
        txn.discard()
        
        @Assert(count, expectedCount)
        
        db.close()
        cleanupConcurrentDir("/tmp/badger_simple_concurrent_test1")
    }
}
