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
    public let MemTableBytes: Int64
    public let ImmCount: Int64
    // 磁盘表
    public let Levels: ArrayList<LevelStats>
    public let TableCount: Int64
    public let TableBytes: Int64
    // 块缓存（关闭时全 0）
    public let BlockCache: BlockCacheStats

    init(gets: Int64, flushes: Int64, compactions: Int64, memTableBytes: Int64, immCount: Int64,
        levels: ArrayList<LevelStats>, tableCount: Int64, tableBytes: Int64, blockCache: BlockCacheStats) {
        this.Gets = gets
        this.Flushes = flushes
        this.Compactions = compactions
        this.MemTableBytes = memTableBytes
        this.ImmCount = immCount
        this.Levels = levels
        this.TableCount = tableCount
        this.TableBytes = tableBytes
        this.BlockCache = blockCache
    }
}
