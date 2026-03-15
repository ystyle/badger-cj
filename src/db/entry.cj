package badgercj.db

import std.time.*
import badgercj.table.Meta

public class Entry {
    public let key: Array<Byte>
    public let value: Array<Byte>
    public let meta: Byte           // 内部标记（bitDelete 等）
    public let userMeta: Byte       // 用户自定义标记
    public let expiresAt: UInt64
    
    public init(
        key: Array<Byte>, 
        value: Array<Byte>, 
        meta!: Byte = 0,
        userMeta!: Byte = 0, 
        expiresAt!: UInt64 = 0
    ) {
        this.key = key
        this.value = value
        this.meta = meta
        this.userMeta = userMeta
        this.expiresAt = expiresAt
    }
    
    public static func new(key: Array<Byte>, value: Array<Byte>): Entry {
        Entry(key, value)
    }
    
    public static func delete(key: Array<Byte>): Entry {
        Entry(key, [], meta: Meta.bitDelete)
    }
    
    public func withMeta(userMeta: Byte): Entry {
        Entry(key, value, meta: meta, userMeta: userMeta, expiresAt: expiresAt)
    }
    
    public func withTTL(dur: Duration): Entry {
        let now = DateTime.now().toUnixTimeStamp()
        Entry(key, value, meta: meta, userMeta: userMeta, 
              expiresAt: UInt64(now.toSeconds()) + UInt64(dur.toSeconds()))
    }
    
    public func withDiscard(): Entry {
        Entry(key, value, meta: meta | Meta.bitDiscardEarlierVersions, 
              userMeta: userMeta, expiresAt: expiresAt)
    }
    
    public func isDelete(): Bool {
        (meta & Meta.bitDelete) != 0
    }
}