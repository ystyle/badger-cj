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
        let headerLen = 9
        let crcLen = 4
        let totalLen = headerLen + key.size + value.size + crcLen
        
        let buf = Array<Byte>(totalLen, repeat: 0)
        
        let keyLen = UInt32(key.size)
        buf[0] = UInt8(keyLen & 0xFF)
        buf[1] = UInt8((keyLen >> 8) & 0xFF)
        buf[2] = UInt8((keyLen >> 16) & 0xFF)
        buf[3] = UInt8((keyLen >> 24) & 0xFF)
        
        let valueLen = UInt32(value.size)
        buf[4] = UInt8(valueLen & 0xFF)
        buf[5] = UInt8((valueLen >> 8) & 0xFF)
        buf[6] = UInt8((valueLen >> 16) & 0xFF)
        buf[7] = UInt8((valueLen >> 24) & 0xFF)
        
        let dataStart = 8
        key.copyTo(buf, 0, dataStart, key.size)
        value.copyTo(buf, 0, dataStart + key.size, value.size)
        
        let metaIdx = dataStart + key.size + value.size
        buf[metaIdx] = meta
        
        let crc = CRC32C()
        crc.write(buf[0..(metaIdx + 1)])
        let checksum = crc.sum32()
        
        let crcIdx = metaIdx + 1
        buf[crcIdx] = UInt8(checksum & 0xFF)
        buf[crcIdx + 1] = UInt8((checksum >> 8) & 0xFF)
        buf[crcIdx + 2] = UInt8((checksum >> 16) & 0xFF)
        buf[crcIdx + 3] = UInt8((checksum >> 24) & 0xFF)
        
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
