package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*
import badgercj.table.*

/**
 * 开库回收「空 WAL」——一条可恢复条目都没有的遗留 `.mem`。
 *
 * 这类文件很普通：进程打开库、还没写就被杀（容器重启、超时 kill、宿主提前 return）。
 * 它没有任何可恢复数据，但**必须由生命周期回收**，否则只会在目录里越积越多，每次开库
 * 都要为它们付一次 `WAL.open` 的预分配 + 映射代价（实测 285 个空 WAL ≈ 7 秒）。
 *
 * 关键认知：判空**不能看文件大小**，遗留形态里没有一种是"0 字节"：
 * ① mmap 后端开库即把段 `ftruncate` 到 2×MemTableSize，崩溃残留是**容量大小的
 *    稀疏全零文件**；② 主段可能被 seal 成 0 字节而数据在 `<base>.1`（首条记录大于段
 *    容量时 rotate 先封口主段）。所以判据是"盘上还能不能解出条目"
 *    （`WAL.hasValidEntriesOnDisk`，跨段、只读）。
 *
 * 回收的删除实现与正常路径共用：正常是 flush 出队后 decrRef → `WAL.delete`；
 * 这里是 `WAL.deleteSegmentFiles`（同一个段命名规则、同一份删除代码）。
 */
@Test
class EmptyWalReclaimTest {

    private func cleanupDir(dir: String): Unit {
        let path = Path(dir)
        if (exists(path)) {
            remove(path, recursive: true)
        }
    }

    // 0 字节 WAL：文件已建但一条都没写（buffered 后端 / 建文件与预分配之间被打断）
    private func touchEmptyWal(dir: String, fid: Int64): String {
        let p = "${dir}/${fid}.mem"
        let f = File(p, OpenMode.Write)
        f.close()
        p
    }

    // 预分配 WAL：长度 = capacity、内容全 0，即 mmap 后端"开库未写就被杀"的真实残留形态
    private func touchPreallocatedWal(dir: String, fid: Int64, size: Int64): String {
        let p = "${dir}/${fid}.mem"
        let f = File(p, OpenMode.Write)
        f.setLength(size)
        f.close()
        p
    }

    @TestCase
    func openReclaimsZeroByteWalFiles() {
        let dir = "/tmp/badger_empty_wal_reclaim"
        cleanupDir(dir)
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)

        // 先落一条真实数据并关库（close 会 flush 成 .sst 并删掉自身 WAL）
        let db1 = Badger.open(opt)
        db1.update({ txn => txn.set("k1".toArray(), "v1".toArray()) })
        db1.close()
        @Assert(testCountFilesWithSuffix(dir, ".mem") == 0, true)

        // 伪造 5 个空 WAL（fid 在现有序列之后，模拟"开库未写即被杀"）
        let emptyFids = ArrayList<Int64>()
        for (i in 0..5) {
            let fid = 10000 + Int64(i)
            touchEmptyWal(dir, fid)
            emptyFids.add(fid)
        }
        @Assert(testCountFilesWithSuffix(dir, ".mem") == 5, true)

        let db2 = Badger.open(opt)
        // 空 WAL 全部回收
        for (fid in emptyFids) {
            @Assert(exists(Path("${dir}/${fid}.mem")), false)
        }
        // 数据不受影响
        match (db2.get("k1".toArray())) {
            case Some(vs) => @Assert(vs.value, "v1".toArray())
            case None => @Fail("k1 lost after reclaiming empty WALs")
        }
        db2.close()
        // 关库后不留任何 WAL
        @Assert(testCountFilesWithSuffix(dir, ".mem") == 0, true)
        cleanupDir(dir)
    }

    // 真实残留形态：容量大小的**全零稀疏文件**（mmap 后端开库即 ftruncate 到 2×MemTableSize）。
    // 这种文件按 size == 0 判不出来，会为每个都建 replay memtable——每份至少一个
    // AtomicStorage 段（8192 × MAX_HEIGHT 个原子对象，约 5MB），几百份同时驻留就把 open
    // 打成 OOM。所以判据必须是"盘上有没有有效条目"。
    @TestCase
    func openReclaimsPreallocatedEmptyWals() {
        let dir = "/tmp/badger_empty_wal_prealloc"
        cleanupDir(dir)
        let mts: UInt64 = 64 * 1024u64
        let opt = Config(dir: dir, memTableSize: mts)

        let db1 = Badger.open(opt)
        db1.update({ txn =>
            txn.set("k1".toArray(), "v1".toArray())
            txn.set("k2".toArray(), "v2".toArray())
        })
        db1.close()

        let n: Int64 = 200
        for (i in 0..n) {
            touchPreallocatedWal(dir, 10000 + i, Int64(mts * 2))
        }
        @Assert(testCountFilesWithSuffix(dir, ".mem") == n, true)

        let db2 = Badger.open(opt)
        // 全部回收，且不因"为每个残留建一个 memtable"而吃满内存
        @Assert(testCountFilesWithSuffix(dir, ".mem") == 1, true)
        @Assert(exists(Path("${dir}/10000.mem")), false)
        @Assert(exists(Path("${dir}/10199.mem")), false)
        match (db2.get("k1".toArray())) {
            case Some(vs) => @Assert(vs.value, "v1".toArray())
            case None => @Fail("k1 lost after reclaiming preallocated empty WALs")
        }
        match (db2.get("k2".toArray())) {
            case Some(vs) => @Assert(vs.value, "v2".toArray())
            case None => @Fail("k2 lost after reclaiming preallocated empty WALs")
        }
        db2.close()
        @Assert(testCountFilesWithSuffix(dir, ".mem") == 0, true)
        cleanupDir(dir)
    }

    // 规模回归：真实事故现场是几百个空 WAL（每次"开库未写即被杀"留一个）。
    // 这里不测时间（那会在 CI 上抖），只钉住"几百个也要全部回收、数据不受影响"。
    @TestCase
    func openReclaimsManyZeroByteWals() {
        let dir = "/tmp/badger_empty_wal_many"
        cleanupDir(dir)
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)

        let db1 = Badger.open(opt)
        db1.update({ txn =>
            txn.set("k1".toArray(), "v1".toArray())
            txn.set("k2".toArray(), "v2".toArray())
        })
        db1.close()

        let n: Int64 = 200
        for (i in 0..n) {
            touchEmptyWal(dir, 10000 + i)
        }
        @Assert(testCountFilesWithSuffix(dir, ".mem") == n, true)

        let db2 = Badger.open(opt)
        // 全部回收（只剩 db2 自己当前 memtable 的 WAL）
        @Assert(testCountFilesWithSuffix(dir, ".mem") == 1, true)
        @Assert(exists(Path("${dir}/10000.mem")), false)
        @Assert(exists(Path("${dir}/10199.mem")), false)
        match (db2.get("k2".toArray())) {
            case Some(vs) => @Assert(vs.value, "v2".toArray())
            case None => @Fail("k2 lost after reclaiming many empty WALs")
        }
        db2.close()
        @Assert(testCountFilesWithSuffix(dir, ".mem") == 0, true)
        cleanupDir(dir)
    }

    // 遗留的非空 WAL 必须照旧 replay → 落盘 → 回收（去掉"重放后为空就丢弃"的过滤后
    // 不能坏）。注意**不能先 close**：close 会 flush 并删掉 WAL，那样根本没东西可重放
    //（进程内也没有目录锁，CrashRecoveryTest.testWalRecoveryWithoutClose 就是同款写法）。
    @TestCase
    func openReplaysLeftoverNonEmptyWal() {
        let dir = "/tmp/badger_empty_replay_reclaim"
        cleanupDir(dir)
        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)

        // 写完不 close：数据只在当前 memtable 的 WAL 里
        let db1 = Badger.open(opt)
        db1.update({ txn => txn.set("k2".toArray(), "v2".toArray()) })
        db1.flushWAL()
        @Assert(testCountFilesWithSuffix(dir, ".mem") == 1, true)
        @Assert(testCountFilesWithSuffix(dir, ".sst") == 0, true)

        let db2 = Badger.open(opt)
        match (db2.get("k2".toArray())) {
            case Some(vs) => @Assert(vs.value, "v2".toArray())
            case None => @Fail("k2 lost after replay")
        }
        // 重放表已落盘、遗留 WAL 已回收（.mem == 1 = db2 当前 memtable 自己的）
        @Assert(testCountFilesWithSuffix(dir, ".mem") == 1, true)
        @Assert(testCountFilesWithSuffix(dir, ".sst") >= 1, true)
        db2.close()
        cleanupDir(dir)
    }

    // 主段 0 字节、数据在 `.1` 段：按文件大小判空会把唯一的数据副本一起删掉。
    // （单条记录大于段容量时 rotate 会先封口主段，主段因此变成 0 字节。）
    @TestCase
    func openKeepsDataInLaterSegment() {
        let dir = "/tmp/badger_empty_wal_seg"
        cleanupDir(dir)
        let base = "${dir}/5.mem"
        let bigValue = ("x".toArray()).repeat(80)
        let w = WAL.open(base, capacity: 64, useMmap: true)
        // WAL 条目里的 key 已带 8 字节 ts 后缀（写入路径就是 keyWithTs(..., commitTs)），
        // value 是 ValueStruct 编码；照写入路径的形态造，replay 出来的数据才可读。
        w.write(keyWithTs("kk".toArray(), 1), ValueStruct(bigValue, version: 1).encode())
        w.flush()
        w.close()

        let f = File(Path(base), Read)
        let baseLen = f.length
        f.close()
        @Assert(baseLen == 0, true)
        @Assert(exists(Path("${base}.1")), true)

        let opt = Config(dir: dir, memTableSize: 64 * 1024u64)
        let db = Badger.open(opt)
        // 数据没丢：重放后落盘可读
        match (db.get("kk".toArray())) {
            case Some(vs) => @Assert(vs.value, bigValue)
            case None => @Fail("data in .1 segment lost on open")
        }
        // 重放落盘后整条 WAL（含 .1 段）才允许回收
        @Assert(exists(Path("${base}.1")), false)
        db.close()
        cleanupDir(dir)
    }
}
