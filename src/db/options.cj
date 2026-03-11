package badgercj.db

/**
 * DBOptions - 数据库配置选项
 * 
 * 默认值与 Go badger 保持一致：
 * - MemTableSize: 64MB
 * - TableSize: 2MB
 * - ValueThreshold: 1MB
 */
public class DBOptions {
    public let Dir: String
    public let ValueDir: String
    public let MemTableSize: UInt64
    public let ValueThreshold: UInt64
    public let MaxLevels: Int
    public let NumLevelZeroTables: Int
    public let TableSize: UInt64
    public let DisableWAL: Bool
    public let DetectConflicts: Bool
    
    public init(
        dir!: String = "",
        valueDir!: String = "",
        memTableSize!: UInt64 = 64 * 1024 * 1024u64,
        valueThreshold!: UInt64 = 1 * 1024 * 1024u64,
        maxLevels!: Int = 7,
        numLevelZeroTables!: Int = 4,
        tableSize!: UInt64 = 2 * 1024 * 1024u64,
        disableWAL!: Bool = false,
        detectConflicts!: Bool = true
    ) {
        this.Dir = dir
        this.ValueDir = valueDir
        this.MemTableSize = memTableSize
        this.ValueThreshold = valueThreshold
        this.MaxLevels = maxLevels
        this.NumLevelZeroTables = numLevelZeroTables
        this.TableSize = tableSize
        this.DisableWAL = disableWAL
        this.DetectConflicts = detectConflicts
    }
    
    public func levelMaxSize(level: Int): UInt64 {
        if (level == 0) {
            return UInt64(NumLevelZeroTables) * TableSize
        }
        return TableSize * UInt64(1 << ((level - 1) * 2))
    }
}
