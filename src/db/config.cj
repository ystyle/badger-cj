package badgercj.db

public class Config {
    public let Dir: String
    public let MemTableSize: UInt64
    public let ValueThreshold: UInt64
    public let MaxLevels: Int
    public let NumLevelZeroTables: Int
    public let DisableWAL: Bool
    public let DetectConflicts: Bool
    public let BloomFalsePositive: Float64
    
    public init(
        dir!: String = "",
        memTableSize!: UInt64 = 64 * 1024 * 1024u64,
        valueThreshold!: UInt64 = 1 * 1024 * 1024u64,
        maxLevels!: Int = 7,
        numLevelZeroTables!: Int = 4,
        disableWAL!: Bool = false,
        detectConflicts!: Bool = true,
        bloomFalsePositive!: Float64 = 0.01
    ) {
        this.Dir = dir
        this.MemTableSize = memTableSize
        this.ValueThreshold = valueThreshold
        this.MaxLevels = maxLevels
        this.NumLevelZeroTables = numLevelZeroTables
        this.DisableWAL = disableWAL
        this.DetectConflicts = detectConflicts
        this.BloomFalsePositive = bloomFalsePositive
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
            bloomFalsePositive: this.BloomFalsePositive
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
            bloomFalsePositive: this.BloomFalsePositive
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
            bloomFalsePositive: this.BloomFalsePositive
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
            bloomFalsePositive: this.BloomFalsePositive
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
            bloomFalsePositive: this.BloomFalsePositive
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
            bloomFalsePositive: this.BloomFalsePositive
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
            bloomFalsePositive: this.BloomFalsePositive
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
            bloomFalsePositive: fp
        )
    }
    
    public func levelMaxSize(level: Int): UInt64 {
        if (level == 0) {
            return UInt64(NumLevelZeroTables) * 2 * 1024 * 1024u64
        }
        return 2 * 1024 * 1024u64 * UInt64(1 << ((level - 1) * 2))
    }
}