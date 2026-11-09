package badgercj.db

import std.collection.*

/**
 * WriteBatch - 用户侧批量写入（对齐 badger-go `batch.go` 语义）。
 *
 * - `set` / `delete` / `setEntry` 累积到内部缓冲；
 * - 达到单事务上限（15% MemTableSize / 条数上限）时**自动切分**：先 flush 已累积条目；
 * - `flush()` 把当前缓冲作为一个事务提交；`cancel()` 丢弃未提交条目并进入取消态；
 * - 提交失败后批进入错误态，后续操作抛异常（错误不会被吞掉）；
 * - 注意：自动切分意味着「一批」可能对应多个事务，失败前已提交的部分不会回滚
 *   （与 go WriteBatch 相同语义——它同样按 maxBatchSize/maxBatchCount 自动 flush）。
 */
public class WriteBatch {
    private let db: Badger
    private let entries: ArrayList<Entry>
    private var pendingSize: Int64
    private var error: ?String
    private var canceled: Bool
    // managed DB：所有切分出来的事务都以该 commitTs 提交（对齐 go WriteBatch.commitTs）
    private let commitTs: ?UInt64

    protected init(db: Badger, commitTs!: ?UInt64 = None) {
        this.db = db
        this.entries = ArrayList<Entry>()
        this.pendingSize = 0
        this.error = None
        this.canceled = false
        this.commitTs = commitTs
    }

    public func set(key: Array<Byte>, value: Array<Byte>): Unit {
        setEntry(Entry.new(key, value))
    }

    public func delete(key: Array<Byte>): Unit {
        setEntry(Entry.delete(key))
    }

    public func setEntry(e: Entry): Unit {
        checkUsable()
        let size = Int64(e.key.size + e.value.size) + 24
        if (entries.size > 0 && wouldExceed(size)) {
            // 自动切分：先把已累积条目作为一个事务提交，再继续收
            flush()
            checkUsable()
        }
        entries.add(e)
        pendingSize += size
    }

    private func wouldExceed(size: Int64): Bool {
        entries.size + 1 > db.getMaxBatchCount() || pendingSize + size > db.getMaxBatchSize()
    }

    /** 提交当前累积条目（空批为空操作）。失败抛异常并置错误态。 */
    public func flush(): Unit {
        if (canceled) {
            throw Exception("WriteBatch canceled")
        }
        if (let Some(msg) <- error) {
            throw Exception(msg)
        }
        if (entries.isEmpty()) {
            return
        }
        let batch = ArrayList<Entry>(entries)
        entries.clear()
        pendingSize = 0
        try {
            match (commitTs) {
                case Some(ts) =>
                    // managed：以指定 commitTs 提交；readTs 同用该 ts（managed 不做冲突检测）
                    let txn = db.newTransactionAt(ts, update: true)
                    for (e in batch) {
                        txn.setEntry(e)
                    }
                    match (txn.commitAt(ts)) {
                        case TxnStatus.Ok => ()
                        case TxnStatus.Conflict => throw TxnConflict()
                        case TxnStatus.Error(msg) => throw Exception(msg)
                    }
                case None =>
                    db.updateOrThrow({ txn =>
                        for (e in batch) {
                            txn.setEntry(e)
                        }
                    })
            }
        } catch (e: Exception) {
            error = Some(e.message)
            throw e
        }
    }

    /** 丢弃未提交条目并进入取消态；此后 set/flush 均抛异常。 */
    public func cancel(): Unit {
        entries.clear()
        pendingSize = 0
        canceled = true
    }

    public func getError(): ?String {
        error
    }

    public func isCanceled(): Bool {
        canceled
    }

    private func checkUsable(): Unit {
        if (canceled) {
            throw Exception("WriteBatch canceled")
        }
        if (let Some(msg) <- error) {
            throw Exception(msg)
        }
    }
}
