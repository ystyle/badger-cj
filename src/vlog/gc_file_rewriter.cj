package badgercj.vlog

import std.collection.*
import badgercj.table.*

/**
 * GCFileRewriter - VLog GC 文件重写器
 * 
 * 用于在 GC 期间批量重写有效 entry
 */
public class GCFileRewriter {
    private let db: VLogGCDB
    private let targetFid: UInt32
    private var entries: ArrayList<(Array<Byte>, LogEntry)>
    private var totalSize: Int64
    private let maxBatchSize: Int64 = 10 * 1024 * 1024
    private let maxBatchCount: Int64 = 1000
    
    public init(db: VLogGCDB, targetFid: UInt32) {
        this.db = db
        this.targetFid = targetFid
        this.entries = ArrayList<(Array<Byte>, LogEntry)>()
        this.totalSize = 0
    }
    
    public func process(entry: LogEntry, offset: UInt32): Bool {
        if (let Some(vs) <- db.getVS(entry.key)) {
            if (vs.isValuePointer()) {
                let vp = ValuePointer.decode(vs.value)
                
                if (vp.fid == targetFid && vp.offset == offset) {
                    entries.add((entry.key, entry))
                    totalSize += entry.size()
                    
                    if (entries.size >= maxBatchCount || totalSize >= maxBatchSize) {
                        flush()
                    }
                }
            }
        }
        return true
    }
    
    public func flush(): Unit {
        if (entries.isEmpty()) {
            return
        }
        
        for ((key, entry) in entries) {
            db.setRaw(key, entry.value, entry.meta, entry.version)
        }
        
        entries = ArrayList<(Array<Byte>, LogEntry)>()
        totalSize = 0
    }
}