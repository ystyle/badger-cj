package badgercj.utils

/**
 * key_utils - key 相关工具函数
 * 
 * 提供字节数组比较、复制、哈希等通用操作
 */

/**
 * compareKeys - 比较两个字节数组
 * 
 * 返回值: < 0 表示 a < b, = 0 表示相等, > 0 表示 a > b
 */
@Frozen
protected func compareKeys(a: Array<Byte>, b: Array<Byte>): Int64 {
    let minLen = if (a.size < b.size) { a.size } else { b.size }
    for (i in 0..minLen) {
        if (a[i] != b[i]) {
            return Int64(a[i]) - Int64(b[i])
        }
    }
    return Int64(a.size) - Int64(b.size)
}

/**
 * keysEqual - 检查两个字节数组是否相等
 */
protected func keysEqual(a: Array<Byte>, b: Array<Byte>): Bool {
    if (a.size != b.size) {
        return false
    }
    for (i in 0..a.size) {
        if (a[i] != b[i]) {
            return false
        }
    }
    return true
}

/**
 * hasPrefix - 检查 key 是否有指定前缀
 */
protected func hasPrefix(key: Array<Byte>, prefix: Array<Byte>): Bool {
    if (prefix.size == 0) {
        return true
    }
    if (key.size < prefix.size) {
        return false
    }
    for (i in 0..prefix.size) {
        if (key[i] != prefix[i]) {
            return false
        }
    }
    return true
}

/**
 * hashKey - 计算 key 的哈希值（DJB2 算法）
 * 
 * 用于冲突检测
 */
@OverflowWrapping
protected func hashKey(key: Array<Byte>): UInt64 {
    var h: UInt64 = 5381
    for (b in key) {
        h = ((h << 5) + h) + UInt64(b)
    }
    h
}