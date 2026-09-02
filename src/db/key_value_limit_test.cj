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
