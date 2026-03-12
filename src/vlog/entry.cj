package badgercj.vlog

import std.collection.*
import badgercj.encoding.*

/**
 * LogEntry - Value Log 中的条目
 * 
 * 格式：
 * ┌──────────────┬──────────────┬──────────┬──────────┬──────────┬─────────┐
 * │ Key Length   │ Value Length │ Key      │ Value    │ Meta     │ CRC32   │
 * │ (4 bytes)    │ (4 bytes)    │ (var)    │ (var)    │ (1 byte) │(4 bytes)│
 * │ uint32 LE    │ uint32 LE    │          │          │          │         │
 * └──────────────┴──────────────┴──────────┴──────────┴──────────┴─────────┘
 */
public class LogEntry {
    public let key: Array<Byte>
    public let value: Array<Byte>
    public let meta: Byte
    public let expiresAt: UInt64
    public let version: UInt64
    
    public init(key: Array<Byte>, value: Array<Byte>, meta!: Byte = 0, 
                expiresAt!: UInt64 = 0, version!: UInt64 = 0) {
        this.key = key
        this.value = value
        this.meta = meta
        this.expiresAt = expiresAt
        this.version = version
    }
    
/**
 * 编码为字节数组
 */
public func encode(): Array<Byte> {
    // 格式：keyLen(4) + valueLen(4) + key + value + meta(1) + crc32(4)
    let headerLen = 9  // keyLen(4) + valueLen(4) + meta(1)
    let crcLen = 4
    let totalLen = headerLen + key.size + value.size + crcLen
    
    let buf = Array<Byte>(totalLen, repeat: 0)
    var idx = 0
    
    // 写入 keyLen
    let keyLen = UInt32(key.size)
    buf[idx] = UInt8(keyLen & 0xFF)
    buf[idx + 1] = UInt8((keyLen >> 8) & 0xFF)
    buf[idx + 2] = UInt8((keyLen >> 16) & 0xFF)
    buf[idx + 3] = UInt8((keyLen >> 24) & 0xFF)
    idx += 4
    
    // 写入 valueLen
    let valueLen = UInt32(value.size)
    buf[idx] = UInt8(valueLen & 0xFF)
    buf[idx + 1] = UInt8((valueLen >> 8) & 0xFF)
    buf[idx + 2] = UInt8((valueLen >> 16) & 0xFF)
    buf[idx + 3] = UInt8((valueLen >> 24) & 0xFF)
    idx += 4
    
    // 写入 key
    for (i in 0..key.size) {
        buf[idx] = key[i]
        idx++
    }
    
    // 写入 value
    for (i in 0..value.size) {
        buf[idx] = value[i]
        idx++
    }
    
    // 写入 meta
    buf[idx] = meta
    idx++
    
    // 计算 CRC (header + key + value + meta)
    let crc = CRC32C()
    crc.write(buf[0..idx])
    let checksum = crc.sum32()
    
    // 写入 CRC
    buf[idx] = UInt8(checksum & 0xFF)
    buf[idx + 1] = UInt8((checksum >> 8) & 0xFF)
    buf[idx + 2] = UInt8((checksum >> 16) & 0xFF)
    buf[idx + 3] = UInt8((checksum >> 24) & 0xFF)
    
    return buf
}
    
    /**
     * 从字节数组解码
     */
    public static func decode(data: Array<Byte>, offset: Int64): (LogEntry, Int64) {
        var off = offset
        
        let keyLen = UInt32(data[off]) |
                     (UInt32(data[off + 1]) << 8) |
                     (UInt32(data[off + 2]) << 16) |
                     (UInt32(data[off + 3]) << 24)
        off += 4
        
        let valueLen = UInt32(data[off]) |
                       (UInt32(data[off + 1]) << 8) |
                       (UInt32(data[off + 2]) << 16) |
                       (UInt32(data[off + 3]) << 24)
        off += 4
        
        let key = data[off..(off + Int64(keyLen))]
        off += Int64(keyLen)
        
        let value = data[off..(off + Int64(valueLen))]
        off += Int64(valueLen)
        
        let meta = data[off]
        off += 1
        
        let storedChecksum = UInt32(data[off]) |
                            (UInt32(data[off + 1]) << 8) |
                            (UInt32(data[off + 2]) << 16) |
                            (UInt32(data[off + 3]) << 24)
        off += 4
        
        let crc = CRC32C()
        crc.write(data[offset..(offset + 9 + Int64(keyLen) + Int64(valueLen))])
        let computedChecksum = crc.sum32()
        
        if (computedChecksum != storedChecksum) {
            throw Exception("Checksum mismatch: expected ${storedChecksum}, got ${computedChecksum}")
        }
        
        let entry = LogEntry(key, value, meta: meta)
        return (entry, off - offset)
    }
    
    /**
     * 计算 Entry 大小（编码后）
     */
    public func size(): Int64 {
        return 4 + 4 + key.size + value.size + 1 + 4
    }
}
