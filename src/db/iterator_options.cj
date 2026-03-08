package badgercj.db

import std.collection.*

/**
 * IteratorOptions - 迭代器配置
 * 
 * 参考：github.com/dgraph-io/badger/v4/iterator.go
 */
public struct IteratorOptions {
    public var prefetchSize: Int64 = 100
    public var prefetchValues: Bool = false
    public var reverse: Bool = false
    public var allVersions: Bool = false
    public var internalAccess: Bool = false
    public var prefix: Array<Byte>
    public var sinceTs: UInt64 = 0
    
    public init() {
        this.prefix = []
    }
    
    public init(
        reverse!: Bool = false,
        prefix!: Array<Byte> = [],
        prefetchValues!: Bool = false,
        allVersions!: Bool = false,
        sinceTs!: UInt64 = 0
    ) {
        this.reverse = reverse
        this.prefix = prefix
        this.prefetchValues = prefetchValues
        this.allVersions = allVersions
        this.sinceTs = sinceTs
        this.prefetchSize = 100
        this.internalAccess = false
    }
}