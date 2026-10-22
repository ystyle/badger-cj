package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.sync.*

// 回归：写管道对每个 WriteRequest 只能 done() 一次（对齐 badger-go 的 done(err) 语义）。
//
// 缺陷形态（≤1.6.21）：Badger.writeRequests() 结尾自己 done() 一遍，
// WritePipeline.runBatch() 的 finally 又 done() 一遍。SyncCounter.dec() 在计数已为 0
// 时保持不变（见 std.sync 文档），所以「没有被复用」的请求看不出问题；但调用方
// wait() 返回后立即把请求归还 WriteRequestPool、reset() 复用到下一批时，上一轮迟到
// 的那次 done() 会把新请求的计数器 1→0，造成两类可观测故障：
//   ① 新 commit 在本批写入完成前被提前唤醒 → commit 返回 Ok，但紧接着的 get 看不到
//      刚写的数据（"commit 成功却读不到"）；
//   ② 若请求在管道仍遍历 entries 时被 reset() 清空，则可能抛
//      ConcurrentModificationException（runBatch markFailed 后以异常文案从
//      updateOrThrow 冒出）、或条目已被清空 → 该次写入永久丢失（全量扫描 key 数偏少）。
//
// 用例是压力型：竞态窗口取决于调度/抢占，单次运行不一定命中；断言对象是最终结果
// （每次 commit 返回后立即可见 + 全量 key 计数），不依赖 sleep 制造时序。
// 修复前实测可复现「commit 返回后立即读缺失」，修复后必须稳定全绿。
// 断言一律后置到 db.close() 之后：回归时也不泄漏 DB 后台协程（防连锁失败）。
@Test
class WritePipelineDoneOnceRegressionTest {

    // 小 memtable 强制轮转（多批、多轮换，扩大请求回收复用时机）；InMemory 免磁盘依赖
    private func openDb(): Badger {
        Badger.open(Config(inMemory: true, memTableSize: 64 * 1024u64, numMemtables: 5))
    }

    // (a) 单线程：updateOrThrow 返回即代表提交完成，紧接着的 get 必须看到刚写的值
    @TestCase
    func testImmediateVisibilityAfterCommit(): Unit {
        let db = openDb()
        let iterations = 6000
        var failure = ""
        for (i in 0..iterations) {
            let key = "k${i}"
            let value = "v${i}"
            db.updateOrThrow({ txn => txn.set(key.toArray(), value.toArray()) })
            match (db.get(key.toArray())) {
                case Some(seen) =>
                    if (bytesToString(seen.value) != value) {
                        failure = "iteration ${i}: 提交返回后读到旧值 ${bytesToString(seen.value)}"
                        break
                    }
                case None =>
                    failure = "iteration ${i}: 提交返回后立即读，刚写的 key 缺失"
                    break
            }
        }
        db.close()
        if (failure != "") {
            throw Exception(failure)
        }
    }

    // (b) 并发：多线程同时 commit，每次返回后立即读；结束后全量扫描 key 数 = 写入数
    @TestCase
    func testConcurrentCommitsNoLostWrite(): Unit {
        let db = openDb()
        let threads = 24
        let perThread = 1500
        let errs = ArrayList<String>()
        let errMutex = Mutex()
        let start = SyncCounter(1)
        let futs = ArrayList<Future<Unit>>()
        for (tid in 0..threads) {
            futs.add(spawn {
                start.waitUntilZero()
                try {
                    for (i in 0..perThread) {
                        let key = "t${tid}_k${i}"
                        let value = "t${tid}_v${i}"
                        db.updateOrThrow({ txn => txn.set(key.toArray(), value.toArray()) })
                        // 提交已返回 → 数据必须已可见（done() 提前唤醒在此暴露）
                        match (db.get(key.toArray())) {
                            case Some(seen) =>
                                if (bytesToString(seen.value) != value) {
                                    synchronized(errMutex) {
                                        errs.add("${key}: 可见值错误 ${bytesToString(seen.value)}")
                                    }
                                }
                            case None =>
                                synchronized(errMutex) {
                                    errs.add("${key}: commit 返回后立即读缺失")
                                }
                        }
                    }
                } catch (e: Exception) {
                    // ConcurrentModificationException 会以 markFailed 文案从 updateOrThrow 抛出
                    synchronized(errMutex) {
                        errs.add("thread ${tid} 写入失败: ${e.message}")
                    }
                }
            })
        }
        start.dec()
        for (f in futs) {
            f.get()
        }

        // 先断言无错误（错误文案比计数差异更能定位竞态形态）
        var firstErr = ""
        var errCount = 0
        synchronized(errMutex) {
            errCount = errs.size
            if (errCount > 0) {
                firstErr = errs[0]
            }
        }
        // 全量扫描：写入的 key 一个都不能少（永久丢失检测）
        let expected = threads * perThread
        var count = 0
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator()
        iter.rewind()
        while (iter.valid()) {
            count++
            iter.next()
        }
        iter.close()
        txn.discard()

        // 断言后置 close：回归时也不泄漏 DB 后台协程（防连锁失败）
        db.close()
        if (errCount > 0) {
            throw Exception("并发写出现 ${errCount} 个错误，首个: ${firstErr}")
        }
        if (count != expected) {
            throw Exception("写入丢失: 期望 ${expected} 个 key，实际 ${count}")
        }
    }
}
