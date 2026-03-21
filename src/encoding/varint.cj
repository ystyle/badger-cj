/**
 * Varint 编解码实现
 * 
 * Varint 是 Protocol Buffers 中使用的变长整数编码方式
 * 用于节省小整数的存储空间
 */
package badgercj.encoding

import std.collection.*

/**
 * Varint 编码器
 */
protected class Varint {
    /**
     * 将 UInt64 编码为 Varint 字节数组
     * 
     * 编码规则：
     * - 每个字节的最高位（bit 7）是继续标志位
     *   - 1: 还有后续字节
     *   - 0: 这是最后一个字节
     * - 剩余 7 位是数据位
     * - 小端序：低位在前，高位在后
     */
    public static func encode(value: UInt64): Array<Byte> {
        // UInt64 最多需要 10 字节
        let buf = Array<Byte>(10, repeat: 0)
        var v = value
        var idx = 0
        
        while (v >= 0x80u64) {
            buf[idx] = UInt8((v & 0x7Fu64) | 0x80u64)
            idx++
            v >>= 7u64
        }
        buf[idx] = UInt8(v)
        idx++
        
        return buf[0..idx]
    }
    
    /**
     * 从字节数组解码 Varint 为 UInt64
     * 
     * 返回：(解码值, 消耗的字节数)
     */
    public static func decode(data: Array<Byte>, offset: Int64): (UInt64, Int64) {
        var result: UInt64 = 0
        var shift: Int64 = 0
        var i = offset
        
        while (i < data.size) {
            let b = UInt64(data[i])
            result |= (b & 0x7Fu64) << shift
            i++
            
            if ((b & 0x80u64) == 0u64) {
                break
            }
            shift += 7
        }
        
        return (result, i - offset)
    }
    
    /**
     * 计算 UInt64 值的 Varint 编码长度
     */
    public static func size(value: UInt64): Int64 {
        var size: Int64 = 0
        var v = value
        
        while (v >= 0x80u64) {
            size++
            v >>= 7u64
        }
        
        return size + 1
    }
}

/**
 * 便捷函数：编码 UInt64 为 Varint
 */
protected func encodeVarint(value: UInt64): Array<Byte> {
    return Varint.encode(value)
}

/**
 * 便捷函数：解码 Varint 为 UInt64
 */
protected func decodeVarint(data: Array<Byte>, offset: Int64): (UInt64, Int64) {
    return Varint.decode(data, offset)
}