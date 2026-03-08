package badgercj.db

import std.collection.*
import badgercj.table.*

/**
 * Item - 迭代器返回的单个项
 * 
 * 参考：github.com/dgraph-io/badger/v4/iterator.go
 */
public class Item {
    public let key: Array<Byte>
    public let value: Array<Byte>
    public let version: UInt64
    public let meta: Byte
    public let userMeta: Byte
    public let expiresAt: UInt64
    
    public init(
        key: Array<Byte>,
        value: Array<Byte>,
        version!: UInt64 = 0,
        meta!: Byte = 0,
        userMeta!: Byte = 0,
        expiresAt!: UInt64 = 0
    ) {
        this.key = key
        this.value = value
        this.version = version
        this.meta = meta
        this.userMeta = userMeta
        this.expiresAt = expiresAt
    }
    
    public func isDelete(): Bool {
        return (meta & Meta.bitDelete) != 0
    }
    
    public func isValuePointer(): Bool {
        return (meta & Meta.bitValuePointer) != 0
    }
    
    public func estimateSize(): Int64 {
        return Int64(key.size) + Int64(value.size) + 16
    }
}