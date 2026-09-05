package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*

// key/value 大小语义回归（对齐 badger-go，issue 追查结论）：
//  - go 在写入前拒绝 key > 65000（表/vlog 格式 UInt16 key 长度字段，txn.go maxKeySize）；
//    cj 此前无 key 检查——大 key 写"成功"、flush 建表时 UInt16 窄化抛系统级异常
//    （Error 逃逸杀写路径协程），数据滞留 imm 无法落盘 → 补齐写前显式拒绝
//  - value 无 64KB 限制：≤ ValueThreshold(默认 1MB) 内联进 LSM、更大走 vlog；
//    cj 此前 memtable 的 UInt16 value 槽造成 [64KB, 1MB) 编码报错断写 → 槽扩 UInt32
@Test
class KeyValueLimitTest {
    private func newDb(dir: String, ioUring!: Bool = true): Badger {
        cleanupDir(dir)
        Badger.open(Config(dir: dir, memTableSize: 1024 * 1024u64, useIoUring: ioUring))
    }

    private func expectException(fn: () -> Unit): Option<String> {
        try {
            fn()
            None
        } catch (e: Exception) {
            Some(e.message)
        }
    }

    // key > 65000：事务与批量两条写路径都在写前拒绝（而非 flush 期炸）
    @TestCase
    func testOversizedKeyRejectedAtWrite() {
        let dir = "/tmp/badger_kvlimit_bigkey"
        let db = newDb(dir)

        let bigKey = Array<Byte>(70000, repeat: 0x4B)
        let msgTxn = expectException({ =>
            db.updateOrThrow({ txn =>
                txn.set(bigKey, "v".toArray())
            })
        })
        println("[kv] txn key=70000 rejected: ${msgTxn}")
        @Assert(msgTxn.isSome(), true)
        if (let Some(m) <- msgTxn) {
            @Assert(m.contains("Key too big"), true)
        }

        let entries = ArrayList<Entry>()
        entries.add(Entry(Array<Byte>(70001, repeat: 0x4C), "v".toArray()))
        let msgBatch = expectException({ => db.batchSet(entries) })
        println("[kv] batch key=70001 rejected: ${msgBatch}")
        @Assert(msgBatch.isSome(), true)

        // 拒绝后写路径仍健康（无 Error 逃逸、无状态破坏）
        db.updateOrThrow({ txn =>
            txn.set("normal_key".toArray(), "normal_value".toArray())
        })
        @Assert(db.get("normal_key".toArray()).isSome(), true)

        db.close()
        cleanupDir(dir)
    }

    // key 恰在 go 上限 65000：写入、flush 落盘（表内 65000+8B ts < 65535）、重启找回全部正常
    @TestCase
    func testKeyAtGoLimitFlushAndReopen() {
        let dir = "/tmp/badger_kvlimit_key65000"
        let db = newDb(dir)

        let bigKey = Array<Byte>(65000, repeat: 0x4D)
        db.updateOrThrow({ txn =>
            txn.set(bigKey, "val_at_limit".toArray())
        })
        db.flushMemTable()
        db.close()

        @Assert(testCountFilesWithSuffix(dir, ".sst") > 0, true)
        let db2 = Badger.open(Config(dir: dir, memTableSize: 1024 * 1024u64))
        if (let Some(vs) <- db2.get(bigKey)) {
            @Assert(vs.value, "val_at_limit".toArray())
        } else {
            @Fail("key=65000 not found after reopen")
        }
        db2.close()
        cleanupDir(dir)
    }

    // value 100KB（> 旧 64KB 编码上限、< ValueThreshold 1MB）：内联写入并跨重启完整找回
    @TestCase
    func testValue100KBInlinePersists() {
        let dir = "/tmp/badger_kvlimit_v100k"
        let db = newDb(dir)

        let v100 = Array<Byte>(100 * 1024, repeat: 0x61)
        db.updateOrThrow({ txn =>
            txn.set("v100k".toArray(), v100)
        })
        db.flushMemTable()
        db.close()

        let db2 = Badger.open(Config(dir: dir, memTableSize: 1024 * 1024u64))
        if (let Some(vs) <- db2.get("v100k".toArray())) {
            @Assert(vs.value.size, v100.size)
            @Assert(vs.value[0], 0x61)
            @Assert(vs.value[v100.size - 1], 0x61)
        } else {
            @Fail("value=100KB not found after reopen")
        }
        db2.close()
        cleanupDir(dir)
    }

    // 回归（v1.6.12 升级漏改 memtable_iterator.cj 的 UInt16 掩码）：100KB 值仍在
    // memtable 时（未 flush），通过事务迭代器（Iterator → MergeIterator →
    // MemTableIterator/LazySkipIterator）读回必须完整——此前 80141 被 & 0xFFFF
    // 截成 14605，materialize 报 "array length 14605, range [6, 80141)" 数组越界。
    // 大 key 经磁盘表 block_iterator key 重建后逐字节完整（首/中/尾），双路径回归：
    //   - cjc 对特定形状「参数化长度闭包构造数组」存在末元素取反的确定性错误代码生成
    //     （docs/issue/2026-09-05-array-closure-ctor-last-byte-flip.md），block_iterator
    //     的 key 重建原用 {j=>} 闭包构造，已改安全构造——本用例防该类缺陷波及读路径
    //   - 内容用非重复模式使块内 diffLen 大（大 key 单条进块，diff≈key 全长）
    @TestCase
    func testLargeKeyReconstructedByteExact() {
        let dir = "/tmp/badger_kvlimit_largekey_rebuild"
        let db = newDb(dir)

        let key1 = patternKey(30000, 7)
        let key2 = patternKey(45000, 13)
        let key3 = patternKey(60000, 29)
        db.updateOrThrow({ txn =>
            txn.set(key1, "v1".toArray())
            txn.set(key2, "v2".toArray())
            txn.set(key3, "v3".toArray())
        })
        db.flushMemTable()
        db.close()

        @Assert(testCountFilesWithSuffix(dir, ".sst") > 0, true)
        let db2 = Badger.open(Config(dir: dir, memTableSize: 1024 * 1024u64))

        // 路径 1：迭代器遍历读回 key，逐字节比对（尾字节是编译器缺陷高发位）
        let expected = ArrayList<Array<Byte>>()
        expected.add(key1)
        expected.add(key2)
        expected.add(key3)
        db2.view({ txn =>
            let iter = txn.newIterator()
            iter.rewind()
            var seen = 0
            while (iter.valid()) {
                let gotKey = iter.item().keyCopy()
                var matched = false
                for (exp in expected) {
                    if (bytesEqual(gotKey, exp)) {
                        matched = true
                        break
                    }
                }
                if (!matched) {
                    @Fail("iterated key mismatch (size=${gotKey.size})")
                }
                seen++
                iter.next()
            }
            iter.close()
            if (seen != expected.size) {
                @Fail("iterated ${seen} keys, want ${expected.size}")
            }
        })

        // 路径 2：get 逐个命中（走 seek + keysEqual）
        if (db2.get(key1).isNone() || db2.get(key2).isNone() || db2.get(key3).isNone()) {
            @Fail("large key get miss after reopen")
        }
        db2.close()
        cleanupDir(dir)
    }

    // 大 key 数据构造：Array(n, repeat) + 循环赋值（规避 {j=>} 闭包构造的编译器缺陷路径）
    private static func patternKey(len: Int64, seed: Int64): Array<Byte> {
        let arr = Array<Byte>(len, repeat: 0)
        var i: Int64 = 0
        while (i < len) {
            arr[i] = UInt8((i * seed + 3) % 256)
            i++
        }
        arr
    }

    private static func bytesEqual(a: Array<Byte>, b: Array<Byte>): Bool {
        if (a.size != b.size) {
            return false
        }
        var i: Int64 = 0
        while (i < a.size) {
            if (a[i] != b[i]) {
                return false
            }
            i++
        }
        true
    }

    @TestCase
    func testValue100KBReadBackViaMemtableIterator() {
        let dir = "/tmp/badger_kvlimit_v100k_iter"
        let db = newDb(dir)

        let v100 = Array<Byte>(100 * 1024, repeat: 0x61)
        db.updateOrThrow({ txn =>
            txn.set("v100k".toArray(), v100)
            txn.set("small".toArray(), "sv".toArray())
        })

        // 不 flush：值仍在 memtable，迭代路径必须走 MemTableIterator
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator()
        iter.rewind()
        var foundBig: Bool = false
        var foundSmall: Bool = false
        while (iter.valid()) {
            let item = iter.item()
            if (bytesToString(item.key) == "v100k") {
                foundBig = true
                @Assert(item.value.size, v100.size)
                @Assert(item.value[0], 0x61)
                @Assert(item.value[v100.size - 1], 0x61)
            } else if (bytesToString(item.key) == "small") {
                foundSmall = true
                @Assert(item.value, "sv".toArray())
            }
            iter.next()
        }
        iter.close()
        @Assert(foundBig, true)
        @Assert(foundSmall, true)

        // seek 路径同样走 MemTableIterator（137 行掩码），必须完整
        let iter2 = txn.newIterator()
        iter2.seek(keyWithTs("v100k".toArray(), 0xFFFFFFFFFFFFFFFFu64))
        if (iter2.valid()) {
            let item = iter2.item()
            @Assert(item.value.size, v100.size)
        } else {
            @Fail("seek v100k not found")
        }
        iter2.close()
        txn.discard()

        db.close()
        cleanupDir(dir)
    }

    // value 2MB（≥ ValueThreshold）：走 vlog 并跨重启完整找回
    @TestCase
    func testValue2MBViaVlogPersists() {
        let dir = "/tmp/badger_kvlimit_v2m"
        let db = newDb(dir)

        let v2m = Array<Byte>(2 * 1024 * 1024, repeat: 0x62)
        db.updateOrThrow({ txn =>
            txn.set("v2m".toArray(), v2m)
        })
        db.close()

        let db2 = Badger.open(Config(dir: dir, memTableSize: 1024 * 1024u64))
        if (let Some(vs) <- db2.get("v2m".toArray())) {
            @Assert(vs.value.size, v2m.size)
            @Assert(vs.value[0], 0x62)
            @Assert(vs.value[v2m.size - 1], 0x62)
        } else {
            @Fail("value=2MB not found after reopen")
        }
        db2.close()
        cleanupDir(dir)
    }
}
