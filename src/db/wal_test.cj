package badgercj.db

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import badgercj.table.*

@Test
class WALTest {
    @TestCase
    func testWALWriteAndRead() {
        let testDir = Path("./test_wal_write")
        if (exists(testDir)) {
            remove(testDir, recursive: true)
        }
        Directory.create(testDir.toString())
        
        let walPath = testDir.toString() + "/test.wal"
        let wal = WAL.open(walPath)
        
        let key1 = "key1".toArray()
        let value1Encoded = ValueStruct("value1".toArray()).encode()
        wal.write(key1, value1Encoded)
        
        let key2 = "key2".toArray()
        let value2Encoded = ValueStruct("value2".toArray(), meta: 0x01).encode()
        wal.write(key2, value2Encoded)
        
        let key3 = "key3".toArray()
        let value3Encoded = ValueStruct("value3".toArray(), userMeta: 0x02, version: 100).encode()
        wal.write(key3, value3Encoded)
        
        let entries = wal.readAll()
        @Assert(entries.size, 3)
        
        let entry1 = entries[0]
        @Assert(entry1.key, "key1".toArray())
        let vs1 = ValueStruct.decode(entry1.value)
        @Assert(vs1.value, "value1".toArray())
        @Assert(vs1.meta, 0)
        @Assert(vs1.userMeta, 0)
        
        let entry2 = entries[1]
        @Assert(entry2.key, "key2".toArray())
        let vs2 = ValueStruct.decode(entry2.value)
        @Assert(vs2.value, "value2".toArray())
        @Assert(vs2.meta, 0x01)
        
        let entry3 = entries[2]
        @Assert(entry3.key, "key3".toArray())
        let vs3 = ValueStruct.decode(entry3.value)
        @Assert(vs3.value, "value3".toArray())
        @Assert(vs3.userMeta, 0x02)
        @Assert(vs3.version, 100)
        
        wal.close()
        
        if (exists(testDir)) {
            remove(testDir, recursive: true)
        }
    }
    
    @TestCase
    func testMmapWALRotatesWhenCapacityExceeded() {
        // 小 capacity 强制换段：写入量远超单段容量 → 应切出多段，且数据一条不少、顺序不变。
        let testDir = Path("./test_wal_rotate")
        if (exists(testDir)) {
            remove(testDir, recursive: true)
        }
        Directory.create(testDir.toString())
        let walPath = testDir.toString() + "/1.mem"
        let cap: Int64 = 4096

        let wal = WAL.open(walPath, capacity: cap, useMmap: true)
        let n: Int64 = 100
        for (i in 0..n) {
            let vs = ValueStruct("value_${i}_padding_padding_padding_padding".toArray())
            wal.write("key_${i}".toArray(), vs.encode())
        }
        wal.close()

        // 换段发生了：存在第二段
        @Expect(exists(Path(walPath + ".1")), true)

        // 全部条目可恢复，且顺序保持
        let rw = WAL.openForRead(walPath, useMmap: true)
        let entries = rw.readAll()
        rw.close()
        @Expect(entries.size, n)
        for (i in 0..n) {
            @Expect(entries[i].key == "key_${i}".toArray(), true)
        }

        // 关闭后各段都截断到实际写入长度（稀疏回收），总大小远小于 n×capacity
        var total: Int64 = 0
        var seg: Int64 = 0
        while (exists(Path(if (seg == 0) { walPath } else { "${walPath}.${seg}" }))) {
            let segPath = if (seg == 0) { walPath } else { "${walPath}.${seg}" }
            let f = File(Path(segPath), Read)
            total += f.length
            f.close()
            seg += 1
        }
        @Expect(total < cap * seg, true)
        @Expect(seg > 1, true)

        remove(testDir, recursive: true)
    }

    @TestCase
    func testBatchSetNoDoubleDoneRace(): Unit {
        // 回归：写管道曾对每个请求 done 两次（writeRequests 与 runBatch 的 finally 各一次），
        // 完成计数被多减一次 → wait() 提前唤醒 → 调用方把请求归还对象池、另一线程取出后
        // reset() 清空 entries，而管道仍在遍历同一请求 → ConcurrentModificationException。
        // 该竞态在真实负载下偶发（单线程连续批量写即可触发），这里用高频批量写覆盖。
        let testDir = Path("./test_batchset_double_done")
        if (exists(testDir)) {
            remove(testDir, recursive: true)
        }
        Directory.create(testDir.toString())
        let db = Badger.open(Config(dir: testDir.toString(), memTableSize: 64 * 1024u64))
        for (i in 0..4000) {
            let entries = ArrayList<Entry>()
            for (j in 0..32) {
                entries.add(Entry.new("k${i}_${j}".toArray(), "value_${j}_padding".toArray()))
            }
            db.batchSet(entries)
        }
        @Expect(db.get("k3999_31".toArray()).isSome(), true)
        db.close()
        remove(testDir, recursive: true)
    }

    @TestCase
    func testWALReplay() {
        let testDir = Path("./test_wal_replay")
        if (exists(testDir)) {
            remove(testDir, recursive: true)
        }
        Directory.create(testDir.toString())
        
        let walPath = testDir.toString() + "/test.wal"
        let wal1 = WAL.open(walPath)
        
        let key1 = "key1".toArray()
        let value1Enc = ValueStruct("value1".toArray()).encode()
        wal1.write(key1, value1Enc)

        let key2 = "key2".toArray()
        let value2Enc = ValueStruct("value2".toArray(), meta: 0x01).encode()
        wal1.write(key2, value2Enc)

        wal1.close()
        
        let opt = Config(dir: testDir.toString(), memTableSize: 1024 * 1024u64)
        let mt = MemTable(opt, 1, false)
        mt.put("dummy".toArray(), ValueStruct("dummy".toArray()))
        
        let wal2 = WAL.open(walPath)
        wal2.replay(mt)
        
        let result1 = mt.get(key1)
        if (let Some(vs1) <- result1) {
            @Assert(vs1.value, "value1".toArray())
        } else {
            @Fail("key1 not found after replay")
        }
        
        let result2 = mt.get(key2)
        if (let Some(vs2) <- result2) {
            @Assert(vs2.value, "value2".toArray())
            @Assert(vs2.meta, 0x01)
        } else {
            @Fail("key2 not found after replay")
        }
        
        wal2.close()
        
        if (exists(testDir)) {
            remove(testDir, recursive: true)
        }
    }
    
    @TestCase
    func testWALDelete() {
        let testDir = Path("./test_wal_delete")
        if (exists(testDir)) {
            remove(testDir, recursive: true)
        }
        Directory.create(testDir.toString())
        
        let walPath = testDir.toString() + "/test.wal"
        let wal = WAL.open(walPath)
        
        @Assert(exists(Path(walPath)), true)
        
        let key1 = "key1".toArray()
        let value1Encoded = ValueStruct("value1".toArray()).encode()
        wal.write(key1, value1Encoded)
        
        wal.delete()
        
        @Assert(exists(Path(walPath)), false)
        
        if (exists(testDir)) {
            remove(testDir, recursive: true)
        }
    }
    
    @TestCase
    func testWALEmptyFile() {
        let testDir = Path("./test_wal_empty")
        if (exists(testDir)) {
            remove(testDir, recursive: true)
        }
        Directory.create(testDir.toString())
        
        let walPath = testDir.toString() + "/test.wal"
        let wal = WAL.open(walPath)
        
        let entries = wal.readAll()
        @Assert(entries.size, 0)
        
        wal.close()
        
        if (exists(testDir)) {
            remove(testDir, recursive: true)
        }
    }
    
    @TestCase
    func testMemTableCrashRecovery() {
        let testDir = Path("./test_wal_crash_recovery")
        if (exists(testDir)) {
            remove(testDir, recursive: true)
        }
        Directory.create(testDir.toString())
        
        let opt = Config(dir: testDir.toString(), memTableSize: 1024 * 1024u64)
        
        let mt1 = MemTable(opt, 1, false)
        mt1.put("key1".toArray(), ValueStruct("value1".toArray()))
        mt1.put("key2".toArray(), ValueStruct("value2".toArray(), meta: 0x01))
        mt1.put("key3".toArray(), ValueStruct("value3".toArray(), userMeta: 0x02, version: 100))
        mt1.closeWAL()
        
        let mt2 = MemTable(opt, 1, true)
        let result1 = mt2.get("key1".toArray())
        if (let Some(vs1) <- result1) {
            @Assert(vs1.value, "value1".toArray())
        } else {
            @Fail("key1 not found after recovery")
        }
        
        let result2 = mt2.get("key2".toArray())
        if (let Some(vs2) <- result2) {
            @Assert(vs2.value, "value2".toArray())
            @Assert(vs2.meta, 0x01)
        } else {
            @Fail("key2 not found after recovery")
        }
        
        let result3 = mt2.get("key3".toArray())
        if (let Some(vs3) <- result3) {
            @Assert(vs3.value, "value3".toArray())
            @Assert(vs3.userMeta, 0x02)
            @Assert(vs3.version, 100)
        } else {
            @Fail("key3 not found after recovery")
        }
        
        mt1.decrRef()
        mt2.decrRef()
        
        if (exists(testDir)) {
            remove(testDir, recursive: true)
        }
    }
}
