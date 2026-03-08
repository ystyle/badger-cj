package badgercj.table

import std.collection.*

/**
 * Value 元数据标志位
 */
public class Meta {
    public static let bitDelete: Byte = 0x01
    public static let bitValuePointer: Byte = 0x02
    public static let bitDiscardEarlierVersions: Byte = 0x04
    public static let bitMergeEntry: Byte = 0x08
    public static let bitExpiresAt: Byte = 0x10
    public static let bitTxn: Byte = 0x40
    public static let bitFinTxn: Byte = 0x80
}

/**
 * ValueStruct - 值结构
 * 
 * 包含值本身或指向 Value Log 的指针
 */
public class ValueStruct {
    public let value: Array<Byte>
    public let meta: Byte
    public let userMeta: Byte
    public let version: UInt64
    public let expiresAt: UInt64
    
    public init(value: Array<Byte>, meta!: Byte = 0, userMeta!: Byte = 0, 
                version!: UInt64 = 0, expiresAt!: UInt64 = 0) {
        this.value = value
        this.meta = meta
        this.userMeta = userMeta
        this.version = version
        this.expiresAt = expiresAt
    }
    
    public func isDelete(): Bool {
        return (meta & Meta.bitDelete) != 0
    }
    
    public func isValuePointer(): Bool {
        return (meta & Meta.bitValuePointer) != 0
    }
    
    public func estimateSize(): Int64 {
        return Int64(value.size) + 10 + 8
    }
    
    public func encode(): Array<Byte> {
        let buf = ArrayList<Byte>()
        
        var encodeMeta = meta
        if (expiresAt > 0) {
            encodeMeta |= Meta.bitExpiresAt
        }
        
        buf.add(encodeMeta)
        buf.add(userMeta)
        
        let versionBytes = encodeVarint(version)
        for (b in versionBytes) {
            buf.add(b)
        }
        
        if (expiresAt > 0) {
            buf.add(UInt8(expiresAt & 0xFF))
            buf.add(UInt8((expiresAt >> 8) & 0xFF))
            buf.add(UInt8((expiresAt >> 16) & 0xFF))
            buf.add(UInt8((expiresAt >> 24) & 0xFF))
            buf.add(UInt8((expiresAt >> 32) & 0xFF))
            buf.add(UInt8((expiresAt >> 40) & 0xFF))
            buf.add(UInt8((expiresAt >> 48) & 0xFF))
            buf.add(UInt8((expiresAt >> 56) & 0xFF))
        }
        
        let valueLen = encodeVarint(UInt64(value.size))
        for (b in valueLen) {
            buf.add(b)
        }
        
        for (b in value) {
            buf.add(b)
        }
        
        return buf.toArray()
    }
    
    public static func decode(encoded: Array<Byte>): ValueStruct {
        var idx = 0
        let meta = encoded[idx]
        idx++
        
        let userMeta = encoded[idx]
        idx++
        
        var version: UInt64 = 0
        var shift: UInt64 = 0
        while (idx < encoded.size) {
            let b = encoded[idx]
            idx++
            version |= UInt64(b & 0x7F) << shift
            if ((b & 0x80) == 0) {
                break
            }
            shift += 7
        }
        
        var expiresAt: UInt64 = 0
        if ((meta & Meta.bitExpiresAt) != 0 && idx + 8 <= encoded.size) {
            expiresAt = UInt64(encoded[idx]) |
                       (UInt64(encoded[idx + 1]) << 8) |
                       (UInt64(encoded[idx + 2]) << 16) |
                       (UInt64(encoded[idx + 3]) << 24) |
                       (UInt64(encoded[idx + 4]) << 32) |
                       (UInt64(encoded[idx + 5]) << 40) |
                       (UInt64(encoded[idx + 6]) << 48) |
                       (UInt64(encoded[idx + 7]) << 56)
            idx += 8
        }
        
        var valueLen: UInt64 = 0
        shift = 0
        while (idx < encoded.size) {
            let b = encoded[idx]
            idx++
            valueLen |= UInt64(b & 0x7F) << shift
            if ((b & 0x80) == 0) {
                break
            }
            shift += 7
        }
        
        let value = encoded[idx..(idx + Int64(valueLen))]
        return ValueStruct(value, meta: meta, userMeta: userMeta, version: version, expiresAt: expiresAt)
    }
    
    private func encodeVarint(v: UInt64): Array<Byte> {
        let result = ArrayList<Byte>()
        var val = v
        
        while (val >= 0x80) {
            result.add(UInt8((val & 0x7F) | 0x80))
            val >>= 7
        }
        result.add(UInt8(val))
        
        return result.toArray()
    }
}

/**
 * ValuePointer - 指向 Value Log 中的值
 */
public struct ValuePointer {
    public let fid: UInt32
    public let len: UInt32
    public let offset: UInt32
    
    public init(fid: UInt32, len: UInt32, offset: UInt32) {
        this.fid = fid
        this.len = len
        this.offset = offset
    }
    
    public func encode(): Array<Byte> {
        let buf = ArrayList<Byte>()
        
        buf.add(UInt8(fid & 0xFF))
        buf.add(UInt8((fid >> 8) & 0xFF))
        buf.add(UInt8((fid >> 16) & 0xFF))
        buf.add(UInt8((fid >> 24) & 0xFF))
        
        buf.add(UInt8(len & 0xFF))
        buf.add(UInt8((len >> 8) & 0xFF))
        buf.add(UInt8((len >> 16) & 0xFF))
        buf.add(UInt8((len >> 24) & 0xFF))
        
        buf.add(UInt8(offset & 0xFF))
        buf.add(UInt8((offset >> 8) & 0xFF))
        buf.add(UInt8((offset >> 16) & 0xFF))
        buf.add(UInt8((offset >> 24) & 0xFF))
        
        return buf.toArray()
    }
    
    public static func decode(data: Array<Byte>): ValuePointer {
        let fid = UInt32(data[0]) |
                 (UInt32(data[1]) << 8) |
                 (UInt32(data[2]) << 16) |
                 (UInt32(data[3]) << 24)
        
        let len = UInt32(data[4]) |
                 (UInt32(data[5]) << 8) |
                 (UInt32(data[6]) << 16) |
                 (UInt32(data[7]) << 24)
        
        let offset = UInt32(data[8]) |
                    (UInt32(data[9]) << 8) |
                    (UInt32(data[10]) << 16) |
                    (UInt32(data[11]) << 24)
        
        return ValuePointer(fid, len, offset)
    }
}