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

public class WriteRequest {
    public var commitTs: UInt64
    private let entries: ArrayList<WriteEntry>
    private var counter: SyncCounter
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
    }
}