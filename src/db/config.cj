package badgercj.db

import badgercj.table.CompressionType

public struct Config {
    public var Dir: String
    public var MemTableSize: UInt64
    public var ValueThreshold: UInt64
    public var MaxLevels: Int
    public var NumLevelZeroTables: Int
    public var DisableWAL: Bool
    public var DetectConflicts: Bool
    public var BloomFalsePositive: Float64
    public var UseIoUring: Bool
    public var InMemory: Bool
    public var Compression: CompressionType
    public var AutoCloseOnExit: Bool
    public var SyncWrites: Bool
    // v2.0：WAL 写路径是否走 mmap（默认开）。关闭则回退 v1.x 的 BufferedOutputStream 路径，
    // 用于性能对比与问题回退（设计 §8）；mmap 模式下文件按 2×MemTableSize 预分配。
    public var MmapWAL: Bool
    // v2.0：VLog 段写路径是否走 mmap（默认开）。关闭则回退无缓冲 File.write（v1.x 路径），
    // 用于性能对比与问题回退；mmap 模式下段按 maxFileSize 稀疏预分配。
    public var MmapVLog: Bool
    // v2.0：SSTable 读是否走只读映射（默认开）。关闭则表数据整表读入 GC 堆（v1.x 路径）。
    // 开启后表数据位于页缓存、物理页可被 OS 回收，消除「堆上限 vs 数据量增长」的结构矛盾。
    public var MmapSSTable: Bool
    // 内存中允许的未落盘 memtable 上限（对齐 badger-go WithNumMemtables 默认 5）：
    // 超过后写路径停顿等待 flusher（背压），约束 flush 峰值内存
    // ≈ NumMemtables × 2 × MemTableSize。
    public var NumMemtables: Int
    // VLog 单段容量（对齐 badger-go ValueLogFileSize，默认 1GB）。
    // GC 只能回收非当前段：段越小、垃圾越容易集中，便于测试与低容量设备。
    public var VLogFileSize: UInt64
    
    public init(
        dir!: String = "",
        memTableSize!: UInt64 = 64 * 1024 * 1024u64,
        valueThreshold!: UInt64 = 1 * 1024 * 1024u64,
        maxLevels!: Int = 7,
        numLevelZeroTables!: Int = 4,
        disableWAL!: Bool = false,
        detectConflicts!: Bool = true,
        bloomFalsePositive!: Float64 = 0.01,
        useIoUring!: Bool = true,
        inMemory!: Bool = false,
        compression!: CompressionType = CompressionType.None,
        autoCloseOnExit!: Bool = false,
        syncWrites!: Bool = false,
        numMemtables!: Int = 5,
        mmapWAL!: Bool = true,
        mmapVLog!: Bool = true,
        mmapSSTable!: Bool = true,
        vlogFileSize!: UInt64 = 1024 * 1024 * 1024u64
    ) {
        this.Dir = dir
        this.MemTableSize = memTableSize
        this.MaxLevels = maxLevels
        this.NumLevelZeroTables = numLevelZeroTables
        this.DetectConflicts = detectConflicts
        this.BloomFalsePositive = bloomFalsePositive
        this.UseIoUring = useIoUring
        this.InMemory = inMemory
        this.Compression = compression
        this.AutoCloseOnExit = autoCloseOnExit
        this.SyncWrites = syncWrites
        this.NumMemtables = numMemtables
        this.VLogFileSize = vlogFileSize
        this.MmapWAL = mmapWAL
        this.MmapVLog = mmapVLog
        this.MmapSSTable = mmapSSTable
        
        // InMemory 模式：ValueThreshold 设为最大值，所有数据进 LSM
        if (inMemory) {
            this.ValueThreshold = UInt64.Max
            this.DisableWAL = true
        } else {
            this.ValueThreshold = valueThreshold
            this.DisableWAL = disableWAL
        }
    }
    
    public func withDir(dir: String): Config {
        var conf = this
        conf.Dir = dir
        conf
    }
    
    public func withMemTableSize(size: UInt64): Config {
        var conf = this
        conf.MemTableSize = size
        conf
    }
    
    public func withValueThreshold(threshold: UInt64): Config {
        var conf = this
        conf.ValueThreshold = threshold
        conf
    }
    
    public func withMaxLevels(maxLevels: Int): Config {
        var conf = this
        conf.MaxLevels = maxLevels
        conf
    }
    
    public func withNumLevelZeroTables(n: Int): Config {
        var conf = this
        conf.NumLevelZeroTables = n
        conf
    }
    
    public func withDisableWAL(disable: Bool): Config {
        var conf = this
        conf.DisableWAL = disable
        conf
    }
    
    public func withDetectConflicts(detect: Bool): Config {
        var conf = this
        conf.DetectConflicts = detect
        conf
    }
    
    public func withBloomFalsePositive(fp: Float64): Config {
        var conf = this
        conf.BloomFalsePositive = fp
        conf
    }
    
    public func withUseIoUring(use: Bool): Config {
        var conf = this
        conf.UseIoUring = use
        conf
    }
    
    public func withInMemory(inMemory: Bool): Config {
        var conf = this
        conf.InMemory = inMemory
        // InMemory 模式需要调整 ValueThreshold 和 DisableWAL
        if (inMemory) {
            conf.ValueThreshold = UInt64.Max
            conf.DisableWAL = true
        }
        conf
    }
    
    public func withCompression(compression: CompressionType): Config {
        var conf = this
        conf.Compression = compression
        conf
    }
    
    public func withAutoCloseOnExit(autoClose: Bool): Config {
        var conf = this
        conf.AutoCloseOnExit = autoClose
        conf
    }
    
    public func withSyncWrites(sync: Bool): Config {
        var conf = this
        conf.SyncWrites = sync
        conf
    }
    
    public func withVLogFileSize(size: UInt64): Config {
        var conf = this
        conf.VLogFileSize = size
        conf
    }
    
    public func withMmapSSTable(use: Bool): Config {
        var conf = this
        conf.MmapSSTable = use
        conf
    }
    
    public func withMmapVLog(use: Bool): Config {
        var conf = this
        conf.MmapVLog = use
        conf
    }
    
    public func withMmapWAL(use: Bool): Config {
        var conf = this
        conf.MmapWAL = use
        conf
    }
    
    public func withNumMemtables(n: Int): Config {
        var conf = this
        conf.NumMemtables = n
        conf
    }
    
    public func levelMaxSize(level: Int): UInt64 {
        if (level == 0) {
            return UInt64(NumLevelZeroTables) * 2 * 1024 * 1024u64
        }
        return 2 * 1024 * 1024u64 * UInt64(1 << ((level - 1) * 2))
    }
}