package badgercj.manifest

import std.collection.*
import badgercj.encoding.*

/**
 * Manifest 变更操作类型
 */
public enum ManifestChangeOp {
    | Create
    | Delete
    | DeleteAll
}

/**
 * ManifestChange - MANIFEST 变更记录
 * 
 * 手动 Protobuf 编码，兼容 Go BadgerDB
 */
public class ManifestChange {
    public let id: UInt64
    public let op: ManifestChangeOp
    public let level: UInt32
    public let keyID: UInt64
    
    public init(id: UInt64, op: ManifestChangeOp, level!: UInt32 = 0, keyID!: UInt64 = 0) {
        this.id = id
        this.op = op
        this.level = level
        this.keyID = keyID
    }
    
    /**
     * 编码为 Protobuf 格式
     */
    public func encode(): Array<Byte> {
        let buf = ArrayList<Byte>()
        
        encodeFieldVarint(buf, 1, id)
        
        encodeFieldVarint(buf, 2, opToUInt64())
        
        encodeFieldVarint(buf, 3, UInt64(level))
        
        if (keyID != 0) {
            encodeFieldVarint(buf, 5, keyID)
        }
        
        return buf.toArray()
    }
    
    private func opToUInt64(): UInt64 {
        match (op) {
            case ManifestChangeOp.Create => 1
            case ManifestChangeOp.Delete => 2
            case ManifestChangeOp.DeleteAll => 3
        }
    }
    
    private func encodeFieldVarint(buf: ArrayList<Byte>, fieldNum: UInt64, value: UInt64): Unit {
        let tag = (fieldNum << 3) | 0
        buf.add(UInt8(tag))
        
        let encoded = Varint.encode(value)
        for (b in encoded) {
            buf.add(b)
        }
    }
    
    /**
     * 从 Protobuf 解码
     */
    public static func decode(data: Array<Byte>, offset: Int64): (ManifestChange, Int64) {
        var off = offset
        var id: UInt64 = 0
        var op: UInt64 = 0
        var level: UInt32 = 0
        var keyID: UInt64 = 0
        
        while (off < data.size) {
            let tag = UInt64(data[off])
            off++
            
            let fieldNum = tag >> 3
            let wireType = tag & 0x7
            
            if (wireType == 0) {
                let (value, size) = Varint.decode(data, off)
                off += size
                
                if (fieldNum == 1) {
                    id = value
                } else if (fieldNum == 2) {
                    op = value
                } else if (fieldNum == 3) {
                    level = UInt32(value)
                } else if (fieldNum == 5) {
                    keyID = value
                }
            }
        }
        
        let change = ManifestChange(id, opFromUInt64(op), level: level, keyID: keyID)
        return (change, off - offset)
    }
    
    private static func opFromUInt64(v: UInt64): ManifestChangeOp {
        if (v == 1) {
            return ManifestChangeOp.Create
        } else if (v == 2) {
            return ManifestChangeOp.Delete
        } else {
            return ManifestChangeOp.DeleteAll
        }
    }
}

/**
 * ManifestChangeSet - 变更集合
 */
public class ManifestChangeSet {
    public let changes: ArrayList<ManifestChange>
    
    public init() {
        this.changes = ArrayList<ManifestChange>()
    }
    
    public init(changes: ArrayList<ManifestChange>) {
        this.changes = changes
    }
    
    /**
     * 编码为 Protobuf 格式
     */
    public func encode(): Array<Byte> {
        let buf = ArrayList<Byte>()
        
        for (change in changes) {
            let encoded = change.encode()
            
            let tag = (1 << 3) | 2
            buf.add(UInt8(tag))
            
            let len = Varint.encode(UInt64(encoded.size))
            for (b in len) {
                buf.add(b)
            }
            
            for (b in encoded) {
                buf.add(b)
            }
        }
        
        return buf.toArray()
    }
    
    /**
     * 从 Protobuf 解码
     */
    public static func decode(data: Array<Byte>): ManifestChangeSet {
        let changes = ArrayList<ManifestChange>()
        var offset: Int64 = 0
        
        while (offset < data.size) {
            let tag = UInt64(data[offset])
            offset++
            
            let fieldNum = tag >> 3
            let wireType = tag & 0x7
            
            if (fieldNum == 1 && wireType == 2) {
                let (len, size) = Varint.decode(data, offset)
                offset += size
                
                let changeData = data[offset..(offset + Int64(len))]
                let (change, _) = ManifestChange.decode(changeData, 0)
                changes.add(change)
                offset += Int64(len)
            }
        }
        
        return ManifestChangeSet(changes)
    }
    
    /**
     * 添加变更
     */
    public func add(change: ManifestChange): Unit {
        changes.add(change)
    }
}
