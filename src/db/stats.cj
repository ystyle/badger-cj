package badgercj.db

import std.collection.ArrayList

// 2.2 运行统计快照（P2-1）。只做「读一次、拿到一致的一份数字」，不承诺跨调用聚合。
public class LevelStats {
    public let Level: Int64
    public let TableCount: Int64
    public let Bytes: Int64

    init(level: Int64, tableCount: Int64, bytes: Int64) {
        this.Level = level
        this.TableCount = tableCount
        this.Bytes = bytes
    }
}

public class BlockCacheStats {
    public let Hits: Int64
    public let Misses: Int64
    public let UsedBytes: Int64

    init(hits: Int64, misses: Int64, usedBytes: Int64) {
        this.Hits = hits
        this.Misses = misses
        this.UsedBytes = usedBytes
    }
}

public class Stats {
    // 读
    public let Gets: Int64
    // 后台活动
    public let Flushes: Int64
    public let Compactions: Int64
    // 内存
    // MemTableBytes：仅当前（写入中的）memtable 已用 arena 字节（2.2.0 口径，保持兼容）
    public let MemTableBytes: Int64
    // MemTableUsedBytes / MemTableArenaBytes：当前 memtable + 全部 imm 的 arena
    // 已用 / 分配总量。两者之比 = arena 利用率（P1-4 的判据：为批次预留的空间有没有被浪费）
    public let MemTableUsedBytes: Int64
    public let MemTableArenaBytes: Int64
    public let ImmCount: Int64
    // 磁盘表
    public let Levels: ArrayList<LevelStats>
    public let TableCount: Int64
    public let TableBytes: Int64
    // 块缓存（关闭时全 0）
    public let BlockCache: BlockCacheStats
    // 历史最大单批 arena 预留字节（P1-4 调优判据：与目标容量里的批次预留对比）
    public let MaxBatchBytes: Int64

    init(gets: Int64, flushes: Int64, compactions: Int64, memTableBytes: Int64,
        memTableUsedBytes: Int64, memTableArenaBytes: Int64, immCount: Int64,
        levels: ArrayList<LevelStats>, tableCount: Int64, tableBytes: Int64, blockCache: BlockCacheStats,
        maxBatchBytes: Int64) {
        this.Gets = gets
        this.Flushes = flushes
        this.Compactions = compactions
        this.MemTableBytes = memTableBytes
        this.MemTableUsedBytes = memTableUsedBytes
        this.MemTableArenaBytes = memTableArenaBytes
        this.ImmCount = immCount
        this.Levels = levels
        this.TableCount = tableCount
        this.TableBytes = tableBytes
        this.BlockCache = blockCache
        this.MaxBatchBytes = maxBatchBytes
    }
}
