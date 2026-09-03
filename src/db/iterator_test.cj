package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.convert.*
import std.fs.*

@Test
class IteratorTest {
    @TestCase
    func testIteratorBasic() {
        let opt = Config(dir: "/tmp/badger_iter_test1", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        db.updateOrThrow({ txn =>
            txn.set("key1".toArray(), "value1".toArray())
            txn.set("key2".toArray(), "value2".toArray())
            txn.set("key3".toArray(), "value3".toArray())
        })
        
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
        let opt = Config(dir: "/tmp/badger_iter_test2", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        db.updateOrThrow({ txn =>
            txn.set("key1".toArray(), "value1".toArray())
            txn.set("key2".toArray(), "value2".toArray())
            txn.set("key3".toArray(), "value3".toArray())
        })
        
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
        let opt = Config(dir: "/tmp/badger_iter_test4", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        db.updateOrThrow({ txn =>
            txn.set("key1".toArray(), "value1".toArray())
            txn.set("key2".toArray(), "value2".toArray())
            txn.set("key3".toArray(), "value3".toArray())
        })
        
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
        let opt = Config(dir: "/tmp/badger_iter_test6", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        db.updateOrThrow({ txn => txn.set("key1".toArray(), "original1".toArray()) })
        
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
        let opt = Config(dir: "/tmp/badger_iter_test8", memTableSize: 1024 * 1024u64)
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
        let opt = Config(dir: "/tmp/badger_iter_test9", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        db.updateOrThrow({ txn =>
            txn.set("key1".toArray(), "value1".toArray())
            txn.set("key2".toArray(), "value2".toArray())
            txn.set("key3".toArray(), "value3".toArray())
        })
        
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
        let opt = Config(dir: "/tmp/badger_iter_test11", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        db.updateOrThrow({ txn =>
            txn.set("key1".toArray(), "version1".toArray())
            txn.set("key1".toArray(), "version2".toArray())
            txn.set("key1".toArray(), "version3".toArray())
        })
        
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
        let opt = Config(dir: "/tmp/badger_iter_test12", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        db.updateOrThrow({ txn =>
            txn.set("prefix1/key1".toArray(), "value1".toArray())
            txn.set("prefix1/key2".toArray(), "value2".toArray())
            txn.set("prefix2/other".toArray(), "value3".toArray())
        })
        
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
        let opt = Config(dir: "/tmp/badger_iter_test14", memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        db.updateOrThrow({ txn =>
            txn.set("key1".toArray(), "value1".toArray())
            txn.set("key2".toArray(), "value2".toArray())
            txn.set("key3".toArray(), "value3".toArray())
            txn.delete("key2".toArray())
        })
        
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
        let dir = "/tmp/badger_iter_test15"
        cleanupIterDir(dir)
        
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        let txn1 = db.newTransaction(update: true)
        txn1.set("key1".toArray(), "value1".toArray())
        txn1.commit()
        
        let txn2 = db.newTransaction(update: false)
        let iter = txn2.newIterator()
        
        let txn3 = db.newTransaction(update: true)
        txn3.set("key2".toArray(), "value2".toArray())
        txn3.commit()
        
        var count: Int64 = 0
        iter.rewind()
        while (iter.valid()) {
            count++
            iter.next()
        }
        
        iter.close()
        
        @Assert(count, 1)
        
        db.close()
        cleanupIterDir(dir)
    }
    
    // ==================== 反向迭代版本链修复（badger key 编码 [userKey][反转ts]）====================
    // 反向迭代同 userKey 版本按「旧→新」到达，必须收集整条版本链取最新有效版本，
    // 否则会把旧版本当最新返回；最新版本为删除/过期时整 key 跳过。
    // 覆盖：多版本覆盖写、删除(tombstone)、重新写入、混合多 key（防止 key 被跳过）、reverse+prefix。
    
    @TestCase
    func testReverseMultiVersion() {
        // 两个事务覆盖写 key1: v1 → v2，反向迭代必须返回 v2（旧 bug 返回 v1）
        let dir = "/tmp/badger_iter_rev_mv1"
        cleanupIterDir(dir)
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        let t1 = db.newTransaction(update: true)
        t1.set("key1".toArray(), "v1".toArray())
        t1.commit()
        let t2 = db.newTransaction(update: true)
        t2.set("key1".toArray(), "v2".toArray())
        t2.commit()
        
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator(opt: IteratorOptions(reverse: true))
        
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
        
        @Assert(keys.size, 1)
        @Assert(keys[0], "key1")
        @Assert(values[0], "v2")  // 必须是最新版本
        
        db.close()
        cleanupIterDir(dir)
    }
    
    @TestCase
    func testReverseMultiVersionMixedKeys() {
        // key2 双版本 + key1/key3 单版本：反向必须返回 key3, key2(最新), key1，
        // 且任何 key 都不能被跳过（collectReverseLatest 消费链后 next() 的 off-by-one 回归）
        let dir = "/tmp/badger_iter_rev_mv2"
        cleanupIterDir(dir)
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        let t1 = db.newTransaction(update: true)
        t1.set("key1".toArray(), "v1a".toArray())
        t1.set("key2".toArray(), "v2a".toArray())
        t1.set("key3".toArray(), "v3a".toArray())
        t1.commit()
        let t2 = db.newTransaction(update: true)
        t2.set("key2".toArray(), "v2b".toArray())
        t2.commit()
        
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator(opt: IteratorOptions(reverse: true))
        
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
        
        @Assert(keys.size, 3)
        @Assert(keys[0], "key3")
        @Assert(values[0], "v3a")
        @Assert(keys[1], "key2")
        @Assert(values[1], "v2b")  // key2 必须是最新版本
        @Assert(keys[2], "key1")
        @Assert(values[2], "v1a")
        
        db.close()
        cleanupIterDir(dir)
    }
    
    @TestCase
    func testReverseDeletedKey() {
        // 写入 key2 后删除：反向迭代必须跳过 key2（tombstone 覆盖旧版本）
        let dir = "/tmp/badger_iter_rev_del"
        cleanupIterDir(dir)
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        let t1 = db.newTransaction(update: true)
        t1.set("key1".toArray(), "v1".toArray())
        t1.set("key2".toArray(), "v2".toArray())
        t1.set("key3".toArray(), "v3".toArray())
        t1.commit()
        let t2 = db.newTransaction(update: true)
        t2.delete("key2".toArray())
        t2.commit()
        
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator(opt: IteratorOptions(reverse: true))
        
        let keys = ArrayList<String>()
        iter.rewind()
        while (iter.valid()) {
            let item = iter.item()
            keys.add(bytesToString(item.key))
            iter.next()
        }
        iter.close()
        
        @Assert(keys.size, 2)
        @Assert(keys[0], "key3")
        @Assert(keys[1], "key1")  // key2 被删除，必须跳过
        
        db.close()
        cleanupIterDir(dir)
    }
    
    @TestCase
    func testReverseDeleteThenRewrite() {
        // 写入 → 删除 → 重新写入：反向必须返回重新写入的最新值（删除被新版本覆盖）
        let dir = "/tmp/badger_iter_rev_del2"
        cleanupIterDir(dir)
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        let t1 = db.newTransaction(update: true)
        t1.set("key1".toArray(), "v1".toArray())
        t1.commit()
        let t2 = db.newTransaction(update: true)
        t2.delete("key1".toArray())
        t2.commit()
        let t3 = db.newTransaction(update: true)
        t3.set("key1".toArray(), "v3".toArray())
        t3.commit()
        
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator(opt: IteratorOptions(reverse: true))
        
        var count: Int64 = 0
        var value = ""
        iter.rewind()
        while (iter.valid()) {
            let item = iter.item()
            count++
            value = bytesToString(item.value)
            iter.next()
        }
        iter.close()
        
        @Assert(count, 1)
        @Assert(value, "v3")  // 删除后的重新写入必须可见
        
        db.close()
        cleanupIterDir(dir)
    }
    
    @TestCase
    func testReversePrefix() {
        // 反向 + prefix 组合：只返回前缀内 key，且按反向顺序
        let dir = "/tmp/badger_iter_rev_prefix"
        cleanupIterDir(dir)
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        let t1 = db.newTransaction(update: true)
        t1.set("a/k1".toArray(), "v1".toArray())
        t1.set("a/k2".toArray(), "v2".toArray())
        t1.set("b/x".toArray(), "vx".toArray())
        t1.commit()
        let t2 = db.newTransaction(update: true)
        t2.set("a/k1".toArray(), "v1b".toArray())
        t2.commit()
        
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator(opt: IteratorOptions(reverse: true, prefix: "a/".toArray()))
        
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
        @Assert(keys[0], "a/k2")
        @Assert(values[0], "v2")
        @Assert(keys[1], "a/k1")
        @Assert(values[1], "v1b")  // 前缀内多版本也要取最新
        
        db.close()
        cleanupIterDir(dir)
    }
    
    @TestCase
    func testReverseAllVersionsUnchanged() {
        // allVersions 模式反向保持原行为（调试用，不修复）：应返回所有版本
        let dir = "/tmp/badger_iter_rev_allver"
        cleanupIterDir(dir)
        let opt = Config(dir: dir, memTableSize: 1024 * 1024u64)
        let db = Badger.open(opt)
        
        let t1 = db.newTransaction(update: true)
        t1.set("key1".toArray(), "v1".toArray())
        t1.commit()
        let t2 = db.newTransaction(update: true)
        t2.set("key1".toArray(), "v2".toArray())
        t2.commit()
        
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator(opt: IteratorOptions(reverse: true, allVersions: true))
        
        let values = ArrayList<String>()
        iter.rewind()
        while (iter.valid()) {
            let item = iter.item()
            values.add(bytesToString(item.value))
            iter.next()
        }
        iter.close()
        
        @Assert(values.size, 2)  // 所有版本都可见（含旧版本）
        
        db.close()
        cleanupIterDir(dir)
    }

    // 回归：reverse seek 在数据已落盘（SSTable，经 TableIterWrapper）时的语义。
    // 修复前 TableIterWrapper.seek 对 reverse 直接透传前向 seek（定位 ≥ key 的第一条）：
    // - seek key 大于表内全部 key → 前向 seek invalid → reverse 迭代空结果
    //   （忆时塔 queryPoints(range(0,Max), reverse) 重启后 0 条——数据在 memtable 时
    //    二分 seek 有 reverse 分支所以 tsdb 单测全绿，落盘后即坏）
    // - seek 落在两 key 之间 → 定位到偏大的 key，起点错位
    // 语义锚点：磁盘表（SSTable，经 TableIterWrapper）的 reverse seek 必须与
    // memtable（MemTableIterator 二分）完全一致——同一数据两种存储，逐 seek 输出相等。
    private func collectReverseSeek(db: Badger, seekKey: String): ArrayList<String> {
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator(opt: IteratorOptions(reverse: true))
        iter.seek(seekKey.toArray())
        let keys = ArrayList<String>()
        while (iter.valid()) {
            keys.add(bytesToString(iter.item().key))
            iter.next()
        }
        iter.close()
        txn.discard()
        keys
    }

    @TestCase
    func testReverseSeekOnDiskTable() {
        // A/B 对照：同数据 memtable（A，不 flush）与 SSTable（B，flush 后 reopen）
        let dirA = "/tmp/badger_iter_rev_seek_mt"
        let dirB = "/tmp/badger_iter_rev_seek_disk"
        cleanupIterDir(dirA)
        cleanupIterDir(dirB)
        let optA = Config(dir: dirA, memTableSize: 1024 * 1024u64)
        let optB = Config(dir: dirB, memTableSize: 1024 * 1024u64)
        let dbA = Badger.open(optA)
        let dbB = Badger.open(optB)

        let writeData = { =>
            dbA.updateOrThrow({ txn =>
                txn.set("key1".toArray(), "v1".toArray())
                txn.set("key2".toArray(), "v2".toArray())
                txn.set("key3".toArray(), "v3".toArray())
                txn.set("key4".toArray(), "v4".toArray())
                txn.set("key5".toArray(), "v5".toArray())
            })
            dbB.updateOrThrow({ txn =>
                txn.set("key1".toArray(), "v1".toArray())
                txn.set("key2".toArray(), "v2".toArray())
                txn.set("key3".toArray(), "v3".toArray())
                txn.set("key4".toArray(), "v4".toArray())
                txn.set("key5".toArray(), "v5".toArray())
            })
        }
        writeData()
        // B：flush 后数据落 L0 SSTable（memtable 空），读迭代走 TableIterWrapper
        dbB.flushMemTable()

        // 多个 seek 目标：存在/不存在/越界（大/小）
        let targets = ArrayList<String>()
        targets.add("key1")     // 最小 key：seek 到自身
        targets.add("key2")     // 中间存在 key
        targets.add("key2.5")   // 两 key 之间（不存在）
        targets.add("key5")     // 最大 key
        targets.add("zzz")      // 大于全部
        targets.add("key0")     // 小于全部
        for (t in targets) {
            let ka = collectReverseSeek(dbA, t)
            let kb = collectReverseSeek(dbB, t)
            @Assert(kb.size == ka.size)
            for (i in 0..ka.size) {
                @Assert(kb[i] == ka[i])
            }
        }

        dbA.close()
        dbB.close()
        cleanupIterDir(dirA)
        cleanupIterDir(dirB)
    }

    // 回归：正向 seek 的目标落在两个 data block 之间（seekKey 大于前一块全部条目、
    // 小于下一块首条——典型的「组前缀型 seek」，如时序库 seek 到
    // "s:<series>:<ts>:" 组首）时，Table.findBlock 按块首 key 把 seekKey 指到
    // 前一块 → 块内二分 miss → 迭代 invalid，漏掉下一块首的 ≥ seekKey 条目
    // （修复前：数据跨多个 block 时此类 seek 静默落空；单块/小表不触发）。
    // 语义锚点：磁盘表 seek 必须与 memtable 二分 seek 一致——同一数据两种存储，
    // 逐 seek 目标输出相等。
    private func collectForwardSeek(db: Badger, seekKey: String): ArrayList<String> {
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator()
        iter.seek(seekKey.toArray())
        let keys = ArrayList<String>()
        var guard = 0
        while (iter.valid() && guard < 8) {
            keys.add(bytesToString(iter.item().key))
            guard += 1
            iter.next()
        }
        iter.close()
        txn.discard()
        keys
    }

    @TestCase
    func testForwardSeekAcrossBlockGap() {
        let dirA = "/tmp/badger_iter_fwd_gap_mt"
        let dirB = "/tmp/badger_iter_fwd_gap_disk"
        cleanupIterDir(dirA)
        cleanupIterDir(dirB)
        let optA = Config(dir: dirA, memTableSize: 1024 * 1024u64)
        let optB = Config(dir: dirB, memTableSize: 1024 * 1024u64)
        let dbA = Badger.open(optA)
        let dbB = Badger.open(optB)
        // 6 组 × 400 定长 seq 点 key（共 2400 key，~160KB）→ SSTable 跨数十个 4KB block
        let padding = "vvvvvvvvvvvvvvvvvvvvvvvvvvvvvv"
        let allKeys = ArrayList<String>()
        for (g in 0..6) {
            for (s in 0..400) {
                allKeys.add("s:g" + g.toString() + ":" + s.format("020"))
            }
        }
        dbA.updateOrThrow({ txn =>
            for (k in allKeys) {
                txn.set(k.toArray(), padding.toArray())
            }
        })
        dbB.updateOrThrow({ txn =>
            for (k in allKeys) {
                txn.set(k.toArray(), padding.toArray())
            }
        })
        dbB.flushMemTable()

        // 候选 seekKey：组前缀型（真实时序库用法）+ 每 4 条 key 剥 1 字节（覆盖
        // 块边界间隙：块首 B 的 B[:-1] 必大于前一块末、小于 B）+ 越界/不存在
        let candidates = ArrayList<String>()
        for (g in 0..6) {
            candidates.add("s:g" + g.toString() + ":")
        }
        for (i in 0..allKeys.size) {
            if (i % 4 == 0) {
                let k = allKeys[i]
                candidates.add(String.fromUtf8(k.toArray()[0..k.size - 1]))
            }
        }
        candidates.add("s:g3:00000000000000000999")   // 组内不存在（超 seq 上限）
        candidates.add("aaa")                          // 小于全部
        candidates.add("zzz")                          // 大于全部
        for (c in candidates) {
            let ka = collectForwardSeek(dbA, c)
            let kb = collectForwardSeek(dbB, c)
            @Assert(kb.size == ka.size)
            for (i in 0..ka.size) {
                @Assert(kb[i] == ka[i])
            }
        }

        dbA.close()
        dbB.close()
        cleanupIterDir(dirA)
        cleanupIterDir(dirB)
    }
}

func cleanupIterDir(path: String) {
    if (exists(Path(path))) {
        remove(Path(path), recursive: true)
    }
}