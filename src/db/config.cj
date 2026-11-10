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
    // compaction 每个 key 至少保留的版本数（对齐 badger-go NumVersionsToKeep，默认 1）。
    // managed DB 必须调大（旧 readTs 要能读到旧版本），否则旧快照会丢数据。
    public var NumVersionsToKeep: Int
    // L2 流式落盘开关（2.2 引入，2.3 起**默认开**）。
    // true：flush/compaction 边构建边写文件，不在内存持有整表字节；false：旧「整表字节 + writeFile」路径。
    // 实测（2.3 评估）：大表 flush 最小可用堆 384→192MB；compaction 峰值 RSS 415→120MB；
    // 吞吐无代价（120.4 vs 129.2 MB/s，p=0.083）。关闭开关可回退旧路径（故障排查手段）。
    // 仅磁盘 + mmap 模式生效；InMemory / MmapSSTable=false 时自动走旧路径。
    public var StreamingSSTable: Bool
    // arena 批次预留字节（2.3）。0 = 默认公式 min(15% × MemTableSize, 2MB)；
    // >0 = 显式值（上限 MemTableSize）。见 arenaTargetBytes()：这决定每张 memtable 的
    // arena 目标容量 = MemTableSize + 预留 + 节点项。
    public var MemTableBatchReserveBytes: UInt64
    // Pebble 式 arena 渐进扩容起点（字节，2.2）。0 = 关闭渐进（每张 memtable 直接用目标值）；
    // 默认 256KB：第一张 memtable 用 256KB，之后每轮换翻倍，封顶目标值
    // （MemTableSize + 15% 批次预留）。小表（目标 < 起点）等于目标值，无渐进过程。
    public var ArenaGrowthStartBytes: UInt64
    // Block Cache 容量（MB，2.1）。默认 0 = 关闭，行为与 2.0.1 完全一致；
    // 建议 64-256，用于把 mmap 模式随机读延迟拉回「整表驻留堆」水平。
    public var BlockCacheSizeMB: UInt64
    // managed 模式（对齐 badger-go OpenManaged）：提交/读取时间戳完全由调用方指定，
    // 不做冲突检测；必须配合 SetDiscardTs 才能回收旧版本（NumVersionsToKeep 需调大）。
    public var ManagedTxns: Bool
    
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
        vlogFileSize!: UInt64 = 1024 * 1024 * 1024u64,
        numVersionsToKeep!: Int = 1,
        managedTxns!: Bool = false,
        blockCacheSizeMB!: UInt64 = 0,
        arenaGrowthStartBytes!: UInt64 = 256 * 1024u64,
        streamingSSTable!: Bool = true,
        memTableBatchReserveBytes!: UInt64 = 0
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
        this.NumVersionsToKeep = if (numVersionsToKeep < 1) { 1 } else { numVersionsToKeep }
        this.ManagedTxns = managedTxns
        this.BlockCacheSizeMB = blockCacheSizeMB
        this.ArenaGrowthStartBytes = arenaGrowthStartBytes
        this.StreamingSSTable = streamingSSTable
        this.MemTableBatchReserveBytes = memTableBatchReserveBytes
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
    
    public func withNumVersionsToKeep(n: Int): Config {
        var conf = this
        conf.NumVersionsToKeep = if (n < 1) { 1 } else { n }
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
    
    // 批次预留（字节）；0 = 默认公式 min(15% × MemTableSize, 2MB)
    public func withMemTableBatchReserveBytes(bytes: UInt64): Config {
        var conf = this
        conf.MemTableBatchReserveBytes = bytes
        conf
    }
    
    public func levelMaxSize(level: Int): UInt64 {
        if (level == 0) {
            return UInt64(NumLevelZeroTables) * 2 * 1024 * 1024u64
        }
        return 2 * 1024 * 1024u64 * UInt64(1 << ((level - 1) * 2))
    }
}