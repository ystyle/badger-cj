package badgercj.vlog

import std.collection.*
import std.sync.*
import std.fs.*
import std.io.*

/**
 * DiscardStats - 跟踪每个 VLog 文件的垃圾统计
 * 
 * 记录每个 VLog 文件中被删除/覆盖的数据大小，
 * 用于 GC 选择垃圾最多的文件进行清理。
 */
protected class DiscardStats {
    private let lock: Mutex
    private var stats: HashMap<UInt32, Int64>
    private let filePath: Path
    private let inMemory: Bool
    
    public init() {
        this.lock = Mutex()
        this.stats = HashMap<UInt32, Int64>()
        this.filePath = Path("")
        this.inMemory = true
    }
    
    public init(dir: Path) {
        this.lock = Mutex()
        this.stats = HashMap<UInt32, Int64>()
        this.filePath = dir.join("DISCARD")
        this.inMemory = false
        load()
    }
    
    public func update(fid: UInt32, discard: Int64): Int64 {
        synchronized (lock) {
            if (discard < 0) {
                stats[fid] = 0
                flush()
                return 0
            }
            
            let current: Int64 = if (stats.contains(fid)) { stats[fid] } else { 0 }
            let newValue = current + discard
            stats[fid] = newValue
            flush()
            return newValue
        }
    }
    
    public func maxDiscard(): (UInt32, Int64) {
        synchronized (lock) {
            var maxFid: UInt32 = 0
            var maxVal: Int64 = 0
            
            for ((fid, val) in stats) {
                if (val > maxVal) {
                    maxVal = val
                    maxFid = fid
                }
            }
            
            return (maxFid, maxVal)
        }
    }
    
    public func get(fid: UInt32): Int64 {
        synchronized (lock) {
            return stats.get(fid) ?? 0
        }
    }
    
    public func clear(fid: UInt32): Unit {
        synchronized (lock) {
            stats.remove(fid)
            flush()
        }
    }
    
    private func load(): Unit {
        if (inMemory || !exists(filePath)) {
            return
        }
        
        try {
            let data = File.readFrom(filePath)
            var i: Int64 = 0
            while (i + 16 <= data.size) {
                let fid = UInt32(bytesToU64(data, i))
                let val = bytesToU64(data, i + 8)
                if (fid > 0) {
                    stats[fid] = Int64(val)
                }
                i += 16
            }
        } catch (e: Exception) {
            // 读取失败不阻塞启动（保留容错语义），但必须可见：
            // discard stats 丢失会让 VLog GC 的丢弃率判断失真。
            println("[badger] discard stats load failed (${filePath}): " + e.toString())
        }
    }
    
    private func flush(): Unit {
        if (inMemory) {
            return
        }
        
        try {
            let data = ArrayList<Byte>()
            for ((fid, val) in stats) {
                u64ToBytes(data, UInt64(fid))
                u64ToBytes(data, UInt64(val))
            }
            File.writeTo(filePath, data.toArray())
        } catch (e: Exception) {
            // 写失败不上抛（保留容错语义），但必须可见：
            // 静默写失败 = 下次启动 discard stats 回退，VLog GC 行为无痕改变。
            println("[badger] discard stats flush failed (${filePath}): " + e.toString())
        }
    }
    
    private func bytesToU64(data: Array<Byte>, offset: Int64): UInt64 {
        var result: UInt64 = 0
        for (i in 0..8) {
            result = (result << 8) | UInt64(data[offset + i] & 0xFF)
        }
        return result
    }
    
    private func u64ToBytes(data: ArrayList<Byte>, val: UInt64): Unit {
        for (i in 0..8) {
            let shift = 56 - i * 8
            let b = (val >> UInt64(shift)) & 0xFFu64
            data.add(UInt8(b))
        }
    }
}