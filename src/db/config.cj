package badgercj.db

import badgercj.table.CompressionType

public class Config {
    public let Dir: String
    public let MemTableSize: UInt64
    public let ValueThreshold: UInt64
    public let MaxLevels: Int
    public let NumLevelZeroTables: Int
    public let DisableWAL: Bool
    public let DetectConflicts: Bool
    public let BloomFalsePositive: Float64
    public let UseIoUring: Bool
    public let InMemory: Bool
    public let Compression: CompressionType
    public let AutoCloseOnExit: Bool
    
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
        autoCloseOnExit!: Bool = false
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
        Config(
            dir: dir,
            memTableSize: this.MemTableSize,
            valueThreshold: this.ValueThreshold,
            maxLevels: this.MaxLevels,
            numLevelZeroTables: this.NumLevelZeroTables,
            disableWAL: this.DisableWAL,
            detectConflicts: this.DetectConflicts,
            bloomFalsePositive: this.BloomFalsePositive,
            useIoUring: this.UseIoUring,
            inMemory: this.InMemory,
            compression: this.Compression,
            autoCloseOnExit: this.AutoCloseOnExit
        )
    }
    
    public func withMemTableSize(size: UInt64): Config {
        Config(
            dir: this.Dir,
            memTableSize: size,
            valueThreshold: this.ValueThreshold,
            maxLevels: this.MaxLevels,
            numLevelZeroTables: this.NumLevelZeroTables,
            disableWAL: this.DisableWAL,
            detectConflicts: this.DetectConflicts,
            bloomFalsePositive: this.BloomFalsePositive,
            useIoUring: this.UseIoUring,
            inMemory: this.InMemory,
            compression: this.Compression,
            autoCloseOnExit: this.AutoCloseOnExit
        )
    }
    
    public func withValueThreshold(threshold: UInt64): Config {
        Config(
            dir: this.Dir,
            memTableSize: this.MemTableSize,
            valueThreshold: threshold,
            maxLevels: this.MaxLevels,
            numLevelZeroTables: this.NumLevelZeroTables,
            disableWAL: this.DisableWAL,
            detectConflicts: this.DetectConflicts,
            bloomFalsePositive: this.BloomFalsePositive,
            useIoUring: this.UseIoUring,
            inMemory: this.InMemory,
            compression: this.Compression,
            autoCloseOnExit: this.AutoCloseOnExit
        )
    }
    
    public func withMaxLevels(maxLevels: Int): Config {
        Config(
            dir: this.Dir,
            memTableSize: this.MemTableSize,
            valueThreshold: this.ValueThreshold,
            maxLevels: maxLevels,
            numLevelZeroTables: this.NumLevelZeroTables,
            disableWAL: this.DisableWAL,
            detectConflicts: this.DetectConflicts,
            bloomFalsePositive: this.BloomFalsePositive,
            useIoUring: this.UseIoUring,
            inMemory: this.InMemory,
            compression: this.Compression,
            autoCloseOnExit: this.AutoCloseOnExit
        )
    }
    
    public func withNumLevelZeroTables(n: Int): Config {
        Config(
            dir: this.Dir,
            memTableSize: this.MemTableSize,
            valueThreshold: this.ValueThreshold,
            maxLevels: this.MaxLevels,
            numLevelZeroTables: n,
            disableWAL: this.DisableWAL,
            detectConflicts: this.DetectConflicts,
            bloomFalsePositive: this.BloomFalsePositive,
            useIoUring: this.UseIoUring,
            inMemory: this.InMemory,
            compression: this.Compression,
            autoCloseOnExit: this.AutoCloseOnExit
        )
    }
    
    public func withDisableWAL(disable: Bool): Config {
        Config(
            dir: this.Dir,
            memTableSize: this.MemTableSize,
            valueThreshold: this.ValueThreshold,
            maxLevels: this.MaxLevels,
            numLevelZeroTables: this.NumLevelZeroTables,
            disableWAL: disable,
            detectConflicts: this.DetectConflicts,
            bloomFalsePositive: this.BloomFalsePositive,
            useIoUring: this.UseIoUring,
            inMemory: this.InMemory,
            compression: this.Compression,
            autoCloseOnExit: this.AutoCloseOnExit
        )
    }
    
    public func withDetectConflicts(detect: Bool): Config {
        Config(
            dir: this.Dir,
            memTableSize: this.MemTableSize,
            valueThreshold: this.ValueThreshold,
            maxLevels: this.MaxLevels,
            numLevelZeroTables: this.NumLevelZeroTables,
            disableWAL: this.DisableWAL,
            detectConflicts: detect,
            bloomFalsePositive: this.BloomFalsePositive,
            useIoUring: this.UseIoUring,
            inMemory: this.InMemory,
            compression: this.Compression,
            autoCloseOnExit: this.AutoCloseOnExit
        )
    }
    
    public func withBloomFalsePositive(fp: Float64): Config {
        Config(
            dir: this.Dir,
            memTableSize: this.MemTableSize,
            valueThreshold: this.ValueThreshold,
            maxLevels: this.MaxLevels,
            numLevelZeroTables: this.NumLevelZeroTables,
            disableWAL: this.DisableWAL,
            detectConflicts: this.DetectConflicts,
            bloomFalsePositive: fp,
            useIoUring: this.UseIoUring,
            inMemory: this.InMemory,
            compression: this.Compression,
            autoCloseOnExit: this.AutoCloseOnExit
        )
    }
    
    public func withUseIoUring(use: Bool): Config {
        Config(
            dir: this.Dir,
            memTableSize: this.MemTableSize,
            valueThreshold: this.ValueThreshold,
            maxLevels: this.MaxLevels,
            numLevelZeroTables: this.NumLevelZeroTables,
            disableWAL: this.DisableWAL,
            detectConflicts: this.DetectConflicts,
            bloomFalsePositive: this.BloomFalsePositive,
            useIoUring: use,
            inMemory: this.InMemory,
            compression: this.Compression,
            autoCloseOnExit: this.AutoCloseOnExit
        )
    }
    
    public func withInMemory(inMemory: Bool): Config {
        Config(
            dir: this.Dir,
            memTableSize: this.MemTableSize,
            valueThreshold: this.ValueThreshold,
            maxLevels: this.MaxLevels,
            numLevelZeroTables: this.NumLevelZeroTables,
            disableWAL: this.DisableWAL,
            detectConflicts: this.DetectConflicts,
            bloomFalsePositive: this.BloomFalsePositive,
            useIoUring: this.UseIoUring,
            inMemory: inMemory,
            compression: this.Compression,
            autoCloseOnExit: this.AutoCloseOnExit
        )
    }
    
    public func withCompression(compression: CompressionType): Config {
        Config(
            dir: this.Dir,
            memTableSize: this.MemTableSize,
            valueThreshold: this.ValueThreshold,
            maxLevels: this.MaxLevels,
            numLevelZeroTables: this.NumLevelZeroTables,
            disableWAL: this.DisableWAL,
            detectConflicts: this.DetectConflicts,
            bloomFalsePositive: this.BloomFalsePositive,
            useIoUring: this.UseIoUring,
            inMemory: this.InMemory,
            compression: compression,
            autoCloseOnExit: this.AutoCloseOnExit
        )
    }
    
    public func withAutoCloseOnExit(autoClose: Bool): Config {
        Config(
            dir: this.Dir,
            memTableSize: this.MemTableSize,
            valueThreshold: this.ValueThreshold,
            maxLevels: this.MaxLevels,
            numLevelZeroTables: this.NumLevelZeroTables,
            disableWAL: this.DisableWAL,
            detectConflicts: this.DetectConflicts,
            bloomFalsePositive: this.BloomFalsePositive,
            useIoUring: this.UseIoUring,
            inMemory: this.InMemory,
            compression: this.Compression,
            autoCloseOnExit: autoClose
        )
    }
    
    public func levelMaxSize(level: Int): UInt64 {
        if (level == 0) {
            return UInt64(NumLevelZeroTables) * 2 * 1024 * 1024u64
        }
        return 2 * 1024 * 1024u64 * UInt64(1 << ((level - 1) * 2))
    }
}