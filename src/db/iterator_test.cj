package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*

@Test
class IteratorTest {
    @TestCase
    func testIteratorBasic() {
        let opt = Config(dir: "/tmp/badger_iter_test1")
        let db = Badger.open(opt)
        
        // 写入测试数据
        db.set("key1".toArray(), "value1".toArray())
        db.set("key2".toArray(), "value2".toArray())
        db.set("key3".toArray(), "value3".toArray())
        
        // 创建事务和迭代器
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator()
        
        // 迭代并收集所有 key
        let keys = ArrayList<String>()
        iter.rewind()
        while (iter.valid()) {
            let item = iter.item()
            let keyStr = bytesToString(item.key)
            println("Found key: '${keyStr}'")
            keys.add(keyStr)
            iter.next()
        }
        
        iter.close()
        
        @Assert(keys.size, 3)
        if (keys.size > 0) {
            @Assert(keys[0], "key1")
        }
        if (keys.size > 1) {
            @Assert(keys[1], "key2")
        }
        if (keys.size > 2) {
            @Assert(keys[2], "key3")
        }
        
        db.close()
        cleanupIterDir("/tmp/badger_iter_test1")
    }
    
    @TestCase
    func testIteratorReverse() {
        let opt = Config(dir: "/tmp/badger_iter_test2")
        let db = Badger.open(opt)
        
        // 写入测试数据
        db.set("key1".toArray(), "value1".toArray())
        db.set("key2".toArray(), "value2".toArray())
        db.set("key3".toArray(), "value3".toArray())
        
        // 创建反向迭代器
        let txn = db.newTransaction(update: false)
        let iterOpts = IteratorOptions(reverse: true)
        let iter = txn.newIterator(opt: iterOpts)
        
        // 反向迭代
        let keys = ArrayList<String>()
        iter.rewind()
        while (iter.valid()) {
            let item = iter.item()
            let keyStr = bytesToString(item.key)
            keys.add(keyStr)
            iter.next()
        }
        
        iter.close()
        
        @Assert(keys.size, 3)
        @Assert(keys[0], "key3")
        @Assert(keys[1], "key2")
        @Assert(keys[2], "key1")
        
        db.close()
        cleanupIterDir("/tmp/badger_iter_test2")
    }
    
    @TestCase
    func testIteratorSeek() {
        let opt = Config(dir: "/tmp/badger_iter_test4")
        let db = Badger.open(opt)
        
        // 写入测试数据
        db.set("key1".toArray(), "value1".toArray())
        db.set("key2".toArray(), "value2".toArray())
        db.set("key3".toArray(), "value3".toArray())
        
        // Seek 到 key2
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator()
        iter.seek("key2".toArray())
        
        // 检查当前位置
        @Assert(iter.valid(), true)
        let item = iter.item()
        let keyStr = bytesToString(item.key)
        @Assert(keyStr, "key2")
        
        iter.close()
        
        db.close()
        cleanupIterDir("/tmp/badger_iter_test4")
    }
    
    @TestCase
    func testIteratorReadYourWrites() {
        let opt = Config(dir: "/tmp/badger_iter_test6")
        let db = Badger.open(opt)
        
        // 写入初始数据
        db.set("key1".toArray(), "original1".toArray())
        
        // 创建 update 事务
        let txn = db.newTransaction(update: true)
        
        // 修改数据
        txn.set("key1".toArray(), "modified1".toArray())
        txn.set("key2".toArray(), "value2".toArray())
        
        // 创建迭代器
        let iter = txn.newIterator()
        
        // 迭代器应该看到未提交的修改
        let keys = ArrayList<String>()
        let values = ArrayList<String>()
        iter.rewind()
        while (iter.valid()) {
            let item = iter.item()
            keys.add(bytesToString(item.key))
            values.add(bytesToString(item.value))
            iter.next()
        }
        
        iter.close()
        
        @Assert(keys.size, 2)
        @Assert(keys[0], "key1")
        @Assert(keys[1], "key2")
        @Assert(values[0], "modified1")
        @Assert(values[1], "value2")
        
        txn.commit()
        db.close()
        cleanupIterDir("/tmp/badger_iter_test6")
    }
    
    @TestCase
    func testIteratorEmpty() {
        let opt = Config(dir: "/tmp/badger_iter_test8")
        let db = Badger.open(opt)
        
        // 不写入任何数据
        
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator()
        
        iter.rewind()
        @Assert(iter.valid(), false)
        
        iter.close()
        db.close()
        cleanupIterDir("/tmp/badger_iter_test8")
    }
    
    @TestCase
    func testIteratorMultipleIterations() {
        let opt = Config(dir: "/tmp/badger_iter_test9")
        let db = Badger.open(opt)
        
        // 写入测试数据
        db.set("key1".toArray(), "value1".toArray())
        db.set("key2".toArray(), "value2".toArray())
        db.set("key3".toArray(), "value3".toArray())
        
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator()
        
        // 第一次迭代
        var count1: Int64 = 0
        iter.rewind()
        while (iter.valid()) {
            count1++
            iter.next()
        }
        
        // 第二次迭代（rewind 后重新开始）
        var count2: Int64 = 0
        iter.rewind()
        while (iter.valid()) {
            count2++
            iter.next()
        }
        
        iter.close()
        
        @Assert(count1, 3)
        @Assert(count2, 3)
        
        db.close()
        cleanupIterDir("/tmp/badger_iter_test9")
    }
    
    @TestCase
    func testIteratorVersionOrder() {
        let opt = Config(dir: "/tmp/badger_iter_test11")
        let db = Badger.open(opt)
        
        // 写入同一 key 的多个版本
        db.set("key1".toArray(), "version1".toArray())
        db.set("key1".toArray(), "version2".toArray())
        db.set("key1".toArray(), "version3".toArray())
        
        // 默认应该只看到最新版本
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator()
        
        var count: Int64 = 0
        var lastValue = ""
        iter.rewind()
        while (iter.valid()) {
            let item = iter.item()
            count++
            lastValue = bytesToString(item.value)
            iter.next()
        }
        
        iter.close()
        
        @Assert(count, 1)  // 只应该看到一个版本
        @Assert(lastValue, "version3")  // 应该是最新版本
        
        db.close()
        cleanupIterDir("/tmp/badger_iter_test11")
    }
    
    @TestCase
    func testIteratorPrefix() {
        let opt = Config(dir: "/tmp/badger_iter_test12")
        let db = Badger.open(opt)
        
        db.set("prefix1/key1".toArray(), "value1".toArray())
        db.set("prefix1/key2".toArray(), "value2".toArray())
        db.set("prefix2/other".toArray(), "value3".toArray())
        
        let txn = db.newTransaction(update: false)
        let iterOpts = IteratorOptions(prefix: "prefix1/".toArray())
        let iter = txn.newIterator(opt: iterOpts)
        
        let keys = ArrayList<String>()
        iter.rewind()
        while (iter.valid()) {
            let item = iter.item()
            keys.add(bytesToString(item.key))
            iter.next()
        }
        
        iter.close()
        
        @Assert(keys.size, 2)
        @Assert(keys[0], "prefix1/key1")
        @Assert(keys[1], "prefix1/key2")
        
        db.close()
        cleanupIterDir("/tmp/badger_iter_test12")
    }
    
    @TestCase
    func testIteratorDelete() {
        let opt = Config(dir: "/tmp/badger_iter_test14")
        let db = Badger.open(opt)
        
        // 写入数据
        db.set("key1".toArray(), "value1".toArray())
        db.set("key2".toArray(), "value2".toArray())
        db.set("key3".toArray(), "value3".toArray())
        
        // 删除 key2
        db.delete("key2".toArray())
        
        // 迭代应该跳过已删除的 key
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator()
        
        let keys = ArrayList<String>()
        iter.rewind()
        while (iter.valid()) {
            let item = iter.item()
            keys.add(bytesToString(item.key))
            iter.next()
        }
        
        iter.close()
        
        @Assert(keys.size, 2)
        @Assert(keys[0], "key1")
        @Assert(keys[1], "key3")  // key2 被删除，应该跳过
        
        db.close()
        cleanupIterDir("/tmp/badger_iter_test14")
    }
    
    @TestCase
    func testIteratorConsistency() {
        let opt = Config(dir: "/tmp/badger_iter_test15")
        let db = Badger.open(opt)
        
        // 事务 1：写入数据
        let txn1 = db.newTransaction(update: true)
        txn1.set("key1".toArray(), "value1".toArray())
        txn1.commit()
        
        // 创建只读事务和迭代器
        let txn2 = db.newTransaction(update: false)
        let iter = txn2.newIterator()
        
        // 事务 3：写入更多数据
        let txn3 = db.newTransaction(update: true)
        txn3.set("key2".toArray(), "value2".toArray())
        txn3.commit()
        
        // 迭代器应该只能看到 key1（基于 txn2 的 readTs）
        var count: Int64 = 0
        iter.rewind()
        while (iter.valid()) {
            count++
            iter.next()
        }
        
        iter.close()
        
        @Assert(count, 1)  // 只能看到 key1
        
        db.close()
        cleanupIterDir("/tmp/badger_iter_test15")
    }
}

func cleanupIterDir(path: String) {
    if (exists(Path(path))) {
        remove(Path(path), recursive: true)
    }
}