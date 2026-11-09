package badgercj.db

import std.sync.*
import std.collection.*
import badgercj.table.*

public struct WriteEntry {
    public let key: Array<Byte>
    public let value: Array<Byte>
    public let isDelete: Bool
    public let meta: Byte
    public let userMeta: Byte
    public let expiresAt: UInt64
    public var vp: ?ValuePointer
    
    public init(
        key: Array<Byte>, 
        value: Array<Byte>, 
        isDelete!: Bool = false,
        meta!: Byte = 0,
        userMeta!: Byte = 0,
        expiresAt!: UInt64 = 0
    ) {
        this.key = key
        this.value = value
        this.isDelete = isDelete
        this.meta = meta
        this.userMeta = userMeta
        this.expiresAt = expiresAt
        this.vp = None
    }
}

// ── 仅测试构建：钉住"每个请求生命周期内 done() 恰好一次" ──
//
// @When[test] / @When[!test] 让发布产物里不出现计数器与分支（非测试构建编译成空函数）。
// 缺陷形态（≤1.6.21）：writeRequests 与 runBatch 的 finally 各 done 一次 —— 每个 commit
// 都会产生一次"同一请求第二次 done"，与调度、负载无关。所以这是**确定性**回归守卫：
// 缺陷代码上必红，修复后必绿，不依赖压测运气（并发压测用例见
// write_pipeline_done_once_test.cj 的另外两条）。
@When[test]
let DONE_TWICE_COUNT = AtomicInt64(0)

@When[test]
func noteDoneForTest(r: WriteRequest): Unit {
    r.doneTimes += 1
    if (r.doneTimes > 1) {
        DONE_TWICE_COUNT.fetchAdd(1)
    }
}

@When[!test]
func noteDoneForTest(r: WriteRequest): Unit {}

@When[test]
func resetDoneForTest(r: WriteRequest): Unit {
    r.doneTimes = 0
}

@When[!test]
func resetDoneForTest(r: WriteRequest): Unit {}

public class WriteRequest {
    public var commitTs: UInt64
    private let entries: ArrayList<WriteEntry>
    private var counter: SyncCounter
    // 仅测试构建：本生命周期内 done() 被调用的次数（reset 时归零）
    @When[test] var doneTimes: Int64 = 0
    // 写入失败错误（对齐 badger-go request.Err）：pipeline 处理本批时抛异常会标记到每个 req，
    // commit() wait 后据此返回 TxnStatus.Error——杜绝"写入失败却返回成功"的静默丢数据
    private var errMsg: ?String = None
    
    public init(commitTs: UInt64) {
        this.commitTs = commitTs
        this.entries = ArrayList<WriteEntry>()
        this.counter = SyncCounter(1)
    }
    
    public init(
        key: Array<Byte>, 
        value: Array<Byte>, 
        commitTs: UInt64, 
        isDelete!: Bool = false,
        meta!: Byte = 0,
        userMeta!: Byte = 0,
        expiresAt!: UInt64 = 0
    ) {
        this.commitTs = commitTs
        this.entries = ArrayList<WriteEntry>()
        this.entries.add(WriteEntry(key, value, isDelete: isDelete, meta: meta, userMeta: userMeta, expiresAt: expiresAt))
        this.counter = SyncCounter(1)
    }
    
    public func addEntry(
        key: Array<Byte>, 
        value: Array<Byte>, 
        isDelete!: Bool = false,
        meta!: Byte = 0,
        userMeta!: Byte = 0,
        expiresAt!: UInt64 = 0
    ): Unit {
        entries.add(WriteEntry(key, value, isDelete: isDelete, meta: meta, userMeta: userMeta, expiresAt: expiresAt))
    }
    
    public func getEntries(): ArrayList<WriteEntry> {
        entries
    }
    
    public func entryCount(): Int64 {
        entries.size
    }
    
    public func wait(): Unit {
        counter.waitUntilZero()
    }
    
    public func done(): Unit {
        noteDoneForTest(this)
        counter.dec()
    }
    
    // 本请求写入失败（首次失败保留，后续失败不覆盖）
    public func markFailed(msg: String): Unit {
        if (this.errMsg.isNone()) {
            this.errMsg = Some(msg)
        }
    }
    
    public func errorOf(): ?String {
        this.errMsg
    }
    
    public func reset(newCommitTs: UInt64): Unit {
        this.commitTs = newCommitTs
        entries.clear()
        this.errMsg = None
        counter = SyncCounter(1)
        resetDoneForTest(this)
    }
}
