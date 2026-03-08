/**
 * CRC32-C (Castagnoli) 实现
 * 
 * 用于 BadgerDB 的数据校验，使用 Castagnoli 多项式 0x82F63B78
 * 参考：https://tools.ietf.org/html/rfc3720
 */
package badgercj.encoding

import std.collection.*
import std.binary.*

// CRC32 Castagnoli 多项式
public const CastagnoliPoly: UInt32 = 0x82F63B78u32

/**
 * CRC32-C 校验算法
 * 
 * 使用 Castagnoli 多项式，比 IEEE 多项式更适合现代硬件
 */
public class CRC32C {
    private let tab: ArrayList<UInt32>
    private var crc: UInt32

    public init() {
        this.tab = makeTable(CastagnoliPoly)
        this.crc = 0u32
    }

    public func size(): Int64 {
        return 4
    }

    public func reset(): Unit {
        this.crc = 0u32
    }

    public func write(p: Array<Byte>): Int64 {
        this.crc = update(this.crc, this.tab, p)
        return p.size
    }

    public func writeByte(b: Byte): Unit {
        this.crc = updateByte(this.crc, this.tab, b)
    }

    public func sum32(): UInt32 {
        return this.crc
    }

    public func sum(): Array<Byte> {
        return u32ToLE(this.crc)
    }
}

/**
 * 生成 CRC32 查找表
 */
@OverflowWrapping
private func makeTable(poly: UInt32): ArrayList<UInt32> {
    let table = ArrayList<UInt32>()
    
    for (i in 0..256) {
        var crc: UInt32 = UInt32(i)
        
        for (_ in 0..8) {
            if ((crc & 1u32) != 0u32) {
                crc = (crc >> 1u32) ^ poly
            } else {
                crc = crc >> 1u32
            }
        }
        
        table.add(crc)
    }
    
    return table
}

/**
 * 更新 CRC32 值
 */
@OverflowWrapping
private func update(crc: UInt32, tab: ArrayList<UInt32>, p: Array<Byte>): UInt32 {
    var c: UInt32 = crc ^ 0xFFFFFFFFu32
    
    for (b in p) {
        let idx: UInt32 = (c ^ UInt32(b)) & 0xFFu32
        let tableVal = tab.get(Int64(idx)).getOrThrow()
        c = (c >> 8u32) ^ tableVal
    }
    
    return c ^ 0xFFFFFFFFu32
}

/**
 * 更新单个字节的 CRC32 值
 */
@OverflowWrapping
private func updateByte(crc: UInt32, tab: ArrayList<UInt32>, b: Byte): UInt32 {
    var c: UInt32 = crc ^ 0xFFFFFFFFu32
    let idx: UInt32 = (c ^ UInt32(b)) & 0xFFu32
    let tableVal = tab.get(Int64(idx)).getOrThrow()
    c = (c >> 8u32) ^ tableVal
    return c ^ 0xFFFFFFFFu32
}

/**
 * 全局 CRC32-C 查找表（避免重复创建）
 */
private let globalTable: ArrayList<UInt32> = makeTable(CastagnoliPoly)

/**
 * 一次性计算 CRC32-C
 */
public func checksumCRC32C(data: Array<Byte>): UInt32 {
    return update(0u32, globalTable, data)
}

/**
 * 将 UInt32 转换为 Little-Endian 字节数组
 * 使用 std.binary 标准库
 */
public func u32ToLE(value: UInt32): Array<Byte> {
    let buffer = Array<Byte>(4, repeat: 0)
    value.writeLittleEndian(buffer)
    return buffer
}

/**
 * 从 Little-Endian 字节数组读取 UInt32
 * 使用 std.binary 标准库
 */
public func u32FromLE(data: Array<Byte>, offset: Int64): UInt32 {
    return UInt32.readLittleEndian(data[offset..])
}

/**
 * 将 UInt64 转换为 Little-Endian 字节数组
 * 使用 std.binary 标准库
 */
public func u64ToLE(value: UInt64): Array<Byte> {
    let buffer = Array<Byte>(8, repeat: 0)
    value.writeLittleEndian(buffer)
    return buffer
}

/**
 * 从 Little-Endian 字节数组读取 UInt64
 * 使用 std.binary 标准库
 */
public func u64FromLE(data: Array<Byte>, offset: Int64): UInt64 {
    return UInt64.readLittleEndian(data[offset..])
}