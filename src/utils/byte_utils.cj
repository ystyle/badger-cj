package badgercj.utils

import std.binary.*

protected func u32ToLE(value: UInt32): Array<Byte> {
    let buffer = Array<Byte>(4, repeat: 0)
    value.writeLittleEndian(buffer)
    return buffer
}

protected func u32FromLE(data: Array<Byte>, offset: Int64): UInt32 {
    return UInt32.readLittleEndian(data[offset..])
}

protected func u64ToLE(value: UInt64): Array<Byte> {
    let buffer = Array<Byte>(8, repeat: 0)
    value.writeLittleEndian(buffer)
    return buffer
}

protected func u64FromLE(data: Array<Byte>, offset: Int64): UInt64 {
    return UInt64.readLittleEndian(data[offset..])
}