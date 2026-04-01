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
        syncWrites!: Bool = false
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
    
    public func levelMaxSize(level: Int): UInt64 {
        if (level == 0) {
            return UInt64(NumLevelZeroTables) * 2 * 1024 * 1024u64
        }
        return 2 * 1024 * 1024u64 * UInt64(1 << ((level - 1) * 2))
    }
}