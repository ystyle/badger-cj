package badgercj.db

import std.collection.*
import std.time.*
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
    
    public func keyCopy(): Array<Byte> {
        let copy = Array<Byte>(key.size, repeat: 0)
        for (i in 0..key.size) {
            copy[i] = key[i]
        }
        return copy
    }
    
    public func valueCopy(): Array<Byte> {
        let copy = Array<Byte>(value.size, repeat: 0)
        for (i in 0..value.size) {
            copy[i] = value[i]
        }
        return copy
    }
    
    public func keySize(): Int64 {
        Int64(key.size)
    }
    
    public func valueSize(): Int64 {
        Int64(value.size)
    }
    
    public func isDelete(): Bool {
        (meta & Meta.bitDelete) != 0
    }
    
    public func isValuePointer(): Bool {
        (meta & Meta.bitValuePointer) != 0
    }
    
    public func discardEarlierVersions(): Bool {
        (meta & Meta.bitDiscardEarlierVersions) != 0
    }
    
    public func isDeletedOrExpired(): Bool {
        (meta & Meta.bitDelete) != 0 || (expiresAt > 0 && checkExpired())
    }
    
    private func checkExpired(): Bool {
        let now = UInt64(DateTime.now().toUnixTimeStamp().toSeconds())
        expiresAt <= now
    }
    
    public func estimateSize(): Int64 {
        Int64(key.size) + Int64(value.size) + 16
    }
    
    public func toString(): String {
        "Item(key=${bytesToHex(key)}, version=${version}, userMeta=${userMeta})"
    }
    
    private func bytesToHex(bytes: Array<Byte>): String {
        let hexChars = "0123456789abcdef"
        var result = ""
        for (b in bytes) {
            let hi = Int64((b >> 4) & 0x0F)
            let lo = Int64(b & 0x0F)
            result += "${hexChars[hi]}${hexChars[lo]}"
        }
        result
    }
}