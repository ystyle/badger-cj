package badgercj.db

import std.sync.*
import std.collection.*
import std.time.*
import badgercj.table.*
import badgercj.utils.compareKeys

/**
 * 合并函数：`existingVal` 是已折叠的值，`newVal` 是本轮新增值；返回值成为新的折叠结果。
 * 常见用途：计数器累加（int/float 编解码）、列表追加（字符串拼接、JSON 数组合并）。
 */
public type MergeFunc = (Array<Byte>, Array<Byte>) -> Array<Byte>

/**
 * MergeOperator - 读-改-写合并算子（对齐 badger-go merge.go）。
 *
 * 语义：
 * - `add(v)` 写入一条带 `bitMergeEntry` 的条目（不覆盖旧值，只是追加一个「待合并的增量」）；
 * - `get()` 读取该 key 的全部版本（allVersions）并按「新的在右」顺序折叠：
 *   `result = f(最旧, ... f(次新, 最新))`，遇到 tombstone/过期或
 *   `bitDiscardEarlierVersions` 立即停止；
 * - 后台线程每隔 `interval` 折叠一次并回写一条带 `bitDiscardEarlierVersions` 的**普通**条目
 *   （不带 merge 位）——后续 compaction 会把更旧的 merge 条目全部回收；
 * - 必须调用 `stop()`（或在 db.close 前）结束后台线程；db.close 也会统一 stop。
 *
 * 为什么回写用普通提交而不是原地改版本：走正常事务路径才能复用写锁/轮换/背压/分组提交，
 * 新值版本必然高于所有旧 merge 条目，配合 discard 位即可让 compaction 回收旧链。
 */
public class MergeOperator {
    private let db: Badger
    private let key: Array<Byte>
    private let merge: MergeFunc
    private let interval: Duration
    private let stopped: AtomicBool
    private let lock: Mutex

    protected init(db: Badger, key: Array<Byte>, merge: MergeFunc, interval: Duration) {
        this.db = db
        this.key = key
        this.merge = merge
        this.interval = interval
        this.stopped = AtomicBool(false)
        this.lock = Mutex()
    }

    /** 追加一个待合并值（带 merge 位，不会被之后 Add 覆盖）。 */
    public func add(val: Array<Byte>): Unit {
        if (stopped.load()) {
            throw BadgerException.databaseClosed()
        }
        db.updateOrThrow({ txn =>
            txn.setEntry(Entry(key, val, meta: Meta.bitMergeEntry))
        })
    }

    /** 读取当前折叠结果；若从未 Add（或已被删除）抛 keyNotFound。 */
    public func get(): Array<Byte> {
        lock.lock()
        try {
            let (value, _) = mergeAll()
            value
        } finally {
            lock.unlock()
        }
    }

    /** 立即执行一次折叠（后台线程也会周期性调用）。折叠结果回写为带 discard 位的普通条目。 */
    public func compact(): Unit {
        lock.lock()
        try {
            let (value, count) = mergeAll()
            if (count <= 1) {
                // 只有单版本：没有可合并的，回写只会不断产生新版本
                return
            }
            db.updateOrThrow({ txn =>
                txn.setEntry(Entry(key, value, meta: Meta.bitDiscardEarlierVersions))
            })
        } finally {
            lock.unlock()
        }
    }

    public func stop(): Unit {
        stopped.store(true)
    }

    internal func isStopped(): Bool {
        stopped.load()
    }

    internal func getInterval(): Duration {
        interval
    }

    /** 折叠该 key 的全部可见版本；返回 (折叠值, 参与折叠的版本数)。 */
    private func mergeAll(): (Array<Byte>, Int64) {
        let txn = db.newTransaction(update: false)
        try {
            let opt = IteratorOptions(allVersions: true, prefix: key)
            let iter = txn.newIterator(opt: opt)
            try {
                var newVal: Array<Byte> = []
                var count: Int64 = 0
                iter.rewind()
                while (iter.valid()) {
                    let item = iter.item()
                    // prefix 是字节前缀：更长的同前缀 key（"a" vs "ab"）要在此截断
                    if (compareKeys(item.keyCopy(), key) != 0) {
                        break
                    }
                    if (item.isDeletedOrExpired()) {
                        // 最新版本是删除/过期：语义上键不存在
                        break
                    }
                    count++
                    if (count == 1) {
                        newVal = item.valueCopy()
                    } else {
                        newVal = merge(item.valueCopy(), newVal)
                    }
                    if (item.discardEarlierVersions()) {
                        // 已折叠过的结果：更旧版本都是它的输入，无需再折叠
                        break
                    }
                    iter.next()
                }
                if (count == 0) {
                    throw BadgerException.keyNotFound()
                }
                (newVal, count)
            } finally {
                iter.close()
            }
        } finally {
            txn.discard()
        }
    }
}
