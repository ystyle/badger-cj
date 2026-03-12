package badgercj.db

import std.collection.*

/**
 * 辅助函数 - Iterator 使用的工具函数
 * 
 * 参考：github.com/dgraph-io/badger/v4/y/y.go
 */

private let badgerPrefix: ArrayList<Byte> = ArrayList<Byte>([98, 97, 100, 103, 101, 114])  // "badger"

/**
 * keyWithTs - 在 key 后追加时间戳（取反，使高版本排在字典序前面）
 * 
 * BadgerDB 的 key 格式: [原始key][8字节时间戳(取反)]
 */
public func keyWithTs(key: Array<Byte>, ts: UInt64): Array<Byte> {
    let keyLen = key.size
    let result = Array<Byte>(keyLen + 8, repeat: 0)
    
    // 复制原始 key
    for (i in 0..keyLen) {
        result[i] = key[i]
    }
    
    // 取反时间戳（~ts），使高版本排在字典序前面
    let invTs = 0xFFFFFFFFFFFFFFFFu64 ^ ts
    result[keyLen] = UInt8((invTs >> 56) & 0xFF)
    result[keyLen + 1] = UInt8((invTs >> 48) & 0xFF)
    result[keyLen + 2] = UInt8((invTs >> 40) & 0xFF)
    result[keyLen + 3] = UInt8((invTs >> 32) & 0xFF)
    result[keyLen + 4] = UInt8((invTs >> 24) & 0xFF)
    result[keyLen + 5] = UInt8((invTs >> 16) & 0xFF)
    result[keyLen + 6] = UInt8((invTs >> 8) & 0xFF)
    result[keyLen + 7] = UInt8(invTs & 0xFF)
    
    return result
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
    
    // 取反还原
    return 0xFFFFFFFFFFFFFFFFu64 ^ ts
}

/**
 * parseKey - 从 key 中提取原始 key（去掉时间戳）
 * 如果 key 太短（<= 8 字节），假设没有时间戳，直接返回原 key
 * 
 * 注意：此函数假设 key 可能带有 8 字节时间戳
 * 对于不带时间戳的 user key（如查询时的 key），需要特别处理
 */
public func parseKey(key: Array<Byte>): Array<Byte> {
    if (key.size <= 8) {
        return key
    }
    
    key[0..key.size - 8]
}

/**
 * parseKeyIfHasTs - 如果 key 带有时间戳则解析，否则返回原 key
 * 用于 sameKey 比较
 */
public func parseKeyIfHasTs(key: Array<Byte>, hasTs: Bool): Array<Byte> {
    if (!hasTs || key.size <= 8) {
        return key
    }
    
    key[0..key.size - 8]
}

/**
 * sameKey - 检查两个 key 是否相同（忽略时间戳）
 * 
 * 假设：第一个参数 a 带时间戳（从存储读取），第二个参数 b 是 user key（不带时间戳）
 * 如果 b 的长度 > 8 且与 a 去掉时间戳后长度相同，说明 b 也带时间戳
 */
public func sameKey(a: Array<Byte>, b: Array<Byte>): Bool {
    // a 带时间戳，提取 user key
    let userKeyA = parseKey(a)
    
    // b 可能带时间戳也可能不带
    // 如果 b 长度 > 8 且去掉时间戳后与 userKeyA 长度相同，则 b 也带时间戳
    let userKeyB = if (b.size > 8 && b.size - 8 == userKeyA.size) {
        parseKey(b)
    } else {
        b
    }
    
    if (userKeyA.size != userKeyB.size) {
        return false
    }
    
    for (i in 0..userKeyA.size) {
        if (userKeyA[i] != userKeyB[i]) {
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

public func manifestPath(dir: String): String {
    "${dir}/MANIFEST"
}

// 将文件ID补零为6位数字，如 1 -> "000001"，1234567 -> "1234567"
private func padFid(fid: UInt64): String {
    let fidStr = fid.toString()
    if (fidStr.size < 6) {
        StringBuilder(r'0', 6i64 - fidStr.size).toString() + fidStr
    } else {
        fidStr
    }
}

public func walPath(dir: String, fid: UInt64): String {
    "${dir}/${padFid(fid)}.wal"
}

public func sstablePath(dir: String, fid: UInt64): String {
    "${dir}/${padFid(fid)}.sst"
}