package badgercj.db

import std.collection.*

/**
 * 辅助函数 - Iterator 使用的工具函数
 * 
 * 参考：github.com/dgraph-io/badger/v4/y/y.go
 */

private let badgerPrefix: ArrayList<Byte> = ArrayList<Byte>([98, 97, 100, 103, 101, 114])  // "badger"

/**
 * keyWithTs - 在 key 后追加时间戳
 * 
 * BadgerDB 的 key 格式: [原始key][8字节时间戳]
 */
public func keyWithTs(key: Array<Byte>, ts: UInt64): Array<Byte> {
    let result = ArrayList<Byte>()
    
    // 复制原始 key
    for (b in key) {
        result.add(b)
    }
    
    // 追加时间戳（大端序）
    result.add(UInt8((ts >> 56) & 0xFF))
    result.add(UInt8((ts >> 48) & 0xFF))
    result.add(UInt8((ts >> 40) & 0xFF))
    result.add(UInt8((ts >> 32) & 0xFF))
    result.add(UInt8((ts >> 24) & 0xFF))
    result.add(UInt8((ts >> 16) & 0xFF))
    result.add(UInt8((ts >> 8) & 0xFF))
    result.add(UInt8(ts & 0xFF))
    
    return result.toArray()
}

/**
 * parseTs - 从 key 中解析时间戳
 */
public func parseTs(key: Array<Byte>): UInt64 {
    if (key.size < 8) {
        return 0
    }
    
    let offset = key.size - 8
    var ts: UInt64 = 0
    
    ts = (ts << 8) | UInt64(key[offset])
    ts = (ts << 8) | UInt64(key[offset + 1])
    ts = (ts << 8) | UInt64(key[offset + 2])
    ts = (ts << 8) | UInt64(key[offset + 3])
    ts = (ts << 8) | UInt64(key[offset + 4])
    ts = (ts << 8) | UInt64(key[offset + 5])
    ts = (ts << 8) | UInt64(key[offset + 6])
    ts = (ts << 8) | UInt64(key[offset + 7])
    
    return ts
}

/**
 * parseKey - 从 key 中提取原始 key（去掉时间戳）
 */
public func parseKey(key: Array<Byte>): Array<Byte> {
    if (key.size <= 8) {
        return []
    }
    
    let result = ArrayList<Byte>()
    for (i in 0..key.size - 8) {
        result.add(key[i])
    }
    
    return result.toArray()
}

/**
 * sameKey - 检查两个 key 是否相同（忽略时间戳）
 */
public func sameKey(a: Array<Byte>, b: Array<Byte>): Bool {
    if (a.size < 8 || b.size < 8) {
        return a == b
    }
    
    if (a.size != b.size) {
        return false
    }
    
    for (i in 0..a.size - 8) {
        if (a[i] != b[i]) {
            return false
        }
    }
    
    return true
}

/**
 * safeCopy - 安全复制数组
 */
public func safeCopy(dst: Array<Byte>, src: Array<Byte>): Array<Byte> {
    if (src.size == 0) {
        return []
    }
    
    let result = ArrayList<Byte>()
    for (b in src) {
        result.add(b)
    }
    
    return result.toArray()
}

/**
 * compareKeys - 比较两个 key（带时间戳）
 */
public func compareKeys(a: Array<Byte>, b: Array<Byte>): Int64 {
    let minLen = if (a.size < b.size) { a.size } else { b.size }
    for (i in 0..minLen) {
        if (a[i] != b[i]) {
            return Int64(a[i]) - Int64(b[i])
        }
    }
    return Int64(a.size) - Int64(b.size)
}

/**
 * isBadgerKey - 检查是否是内部 key
 */
public func isBadgerKey(key: Array<Byte>): Bool {
    if (key.size < badgerPrefix.size) {
        return false
    }
    
    for (i in 0..badgerPrefix.size) {
        if (key[i] != badgerPrefix[i]) {
            return false
        }
    }
    
    return true
}