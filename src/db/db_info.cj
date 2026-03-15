package badgercj.db

public class SSTableInfo {
    public let ID: UInt64
    public let Level: Int
    public let Left: Array<Byte>
    public let Right: Array<Byte>
    public let KeyCount: UInt32
    public let OnDiskSize: UInt32
    public let MaxVersion: UInt64
    
    public init(
        id!: UInt64 = 0,
        level!: Int = 0,
        left!: Array<Byte> = [],
        right!: Array<Byte> = [],
        keyCount!: UInt32 = 0,
        onDiskSize!: UInt32 = 0,
        maxVersion!: UInt64 = 0
    ) {
        this.ID = id
        this.Level = level
        this.Left = left
        this.Right = right
        this.KeyCount = keyCount
        this.OnDiskSize = onDiskSize
        this.MaxVersion = maxVersion
    }
}

public class LevelInfo {
    public let Level: Int
    public let NumTables: Int64
    public let Size: Int64
    public let TargetSize: Int64
    
    public init(
        level!: Int = 0,
        numTables!: Int64 = 0,
        size!: Int64 = 0,
        targetSize!: Int64 = 0
    ) {
        this.Level = level
        this.NumTables = numTables
        this.Size = size
        this.TargetSize = targetSize
    }
}

public class DBSize {
    public let LSM: Int64
    public let VLog: Int64
    
    public init(lsm!: Int64 = 0, vlog!: Int64 = 0) {
        this.LSM = lsm
        this.VLog = vlog
    }
}