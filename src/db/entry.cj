package badgercj.db

import std.time.*
import badgercj.table.Meta

public class Entry {
    public let key: Array<Byte>
    public let value: Array<Byte>
    public let userMeta: Byte
    public let expiresAt: UInt64
    
    public init(
        key: Array<Byte>, 
        value: Array<Byte>, 
        userMeta!: Byte = 0, 
        expiresAt!: UInt64 = 0
    ) {
        this.key = key
        this.value = value
        this.userMeta = userMeta
        this.expiresAt = expiresAt
    }
    
    public static func new(key: Array<Byte>, value: Array<Byte>): Entry {
        Entry(key, value)
    }
    
    public static func delete(key: Array<Byte>): Entry {
        Entry(key, [], userMeta: Meta.bitDelete)
    }
    
    public func withMeta(meta: Byte): Entry {
        Entry(key, value, userMeta: meta, expiresAt: expiresAt)
    }
    
    public func withTTL(dur: Duration): Entry {
        let now = DateTime.now().toUnixTimeStamp()
        Entry(key, value, userMeta: userMeta, expiresAt: UInt64(now.toSeconds()) + UInt64(dur.toSeconds()))
    }
    
    public func withDiscard(): Entry {
        Entry(key, value, userMeta: userMeta | Meta.bitDiscardEarlierVersions, expiresAt: expiresAt)
    }
    
    public func isDelete(): Bool {
        (userMeta & Meta.bitDelete) != 0
    }
}