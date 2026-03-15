package badgercj.db

import std.collection.*

/**
 * IteratorOptions - 迭代器配置
 * 
 * 参考：github.com/dgraph-io/badger/v4/iterator.go
 */
public struct IteratorOptions {
    public var prefetchSize: Int64 = 100
    public var prefetchValues: Bool = true
    public var reverse: Bool = false
    public var allVersions: Bool = false
    public var internalAccess: Bool = false
    public var prefix: Array<Byte>
    public var sinceTs: UInt64 = 0
    
    public init(
        prefetchSize!: Int64 = 100,
        prefetchValues!: Bool = true,
        reverse!: Bool = false,
        allVersions!: Bool = false,
        prefix!: Array<Byte> = [],
        sinceTs!: UInt64 = 0
    ) {
        this.prefetchSize = prefetchSize
        this.prefetchValues = prefetchValues
        this.reverse = reverse
        this.allVersions = allVersions
        this.prefix = prefix
        this.sinceTs = sinceTs
        this.internalAccess = false
    }
}

public let DefaultIteratorOptions = IteratorOptions()