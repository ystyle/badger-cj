package badgercj.vlog

import std.collection.*
import badgercj.table.*

public type DiscardChecker = (Array<Byte>, ValueStruct) -> Bool

/**
 * GCFileRewriter - VLog GC 文件重写器
 * 
 * 用于在 GC 期间批量重写有效 entry，同时统计垃圾大小
 */
protected class GCFileRewriter {
    private let db: VLogGCDB
    private let targetFid: UInt32
    private let shouldDiscard: DiscardChecker
    // (key, value, userMeta, expiresAt)：活条目按正常写路径重新落 vlog/更新指针，
    // 不能 setRaw 内联——那会把大值搬进 LSM，且 vlog 条目不保存 version/expiresAt。
    private var entries: ArrayList<(Array<Byte>, Array<Byte>, Byte, UInt64)>
    private var totalSize: Int64
    private var discardSize: Int64
    private let maxBatchSize: Int64 = 10 * 1024 * 1024
    private let maxBatchCount: Int64 = 1000
    
    public init(db: VLogGCDB, targetFid: UInt32, shouldDiscard!: DiscardChecker = { _, _ => false }) {
        this.db = db
        this.targetFid = targetFid
        this.shouldDiscard = shouldDiscard
        this.entries = ArrayList<(Array<Byte>, Array<Byte>, Byte, UInt64)>()
        this.totalSize = 0
        this.discardSize = 0
    }
    
    public func process(entry: LogEntry, offset: UInt32): Bool {
        let entrySize = entry.size()
        
        if (let Some(vs) <- db.getVS(entry.key)) {
            if (!shouldDiscard(entry.key, vs) && vs.isValuePointer()) {
                let vp = ValuePointer.decode(vs.value)
                
                // 只有「当前 LSM 值正好指向本段本偏移」的条目才是活的
                if (vp.fid == targetFid && vp.offset == offset) {
                    // expiresAt 从当前 LSM 值取：vlog 条目编码里不保存它
                    entries.add((entry.key, entry.value, vs.userMeta, vs.expiresAt))
                    totalSize += entrySize
                    
                    if (entries.size >= maxBatchCount || totalSize >= maxBatchSize) {
                        flush()
                    }
                    return true
                }
            }
        }
        
        discardSize += entrySize
        return true
    }
    
    public func flush(): Unit {
        if (entries.isEmpty()) {
            return
        }
        
        db.rewriteBatch(entries)
        
        entries = ArrayList<(Array<Byte>, Array<Byte>, Byte, UInt64)>()
        totalSize = 0
    }
    
    public func getDiscardSize(): Int64 {
        discardSize
    }
}