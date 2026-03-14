/**
 * Skiplist Node 结构
 * 
 * Node 存储在 Arena 中，使用偏移量而非指针
 * 
 * 内存布局（在 Arena 中）：
 * - reserved (UInt64): 保留字段
 * - keyOffset (UInt32): Key 在 Arena 中的偏移量
 * - keySize (UInt16): Key 长度
 * - height (UInt16): 节点高度
 * - atomicIdx (Int64): 在 AtomicStorage 中的索引
 */
package badgercj.skiplist

import badgercj.arena.*
import std.sync.*

public class Node {
    private let arena: Arena
    private let offset: UInt32
    private let atomicStorage: AtomicStorage
    
    public init(arena: Arena, offset: UInt32, atomicStorage: AtomicStorage) {
        this.arena = arena
        this.offset = offset
        this.atomicStorage = atomicStorage
    }
    
    public func getOffset(): UInt32 {
        return offset
    }
    
    public func getAtomicIdx(): Int64 {
        return arena.getI64(offset + 16)
    }
    
    public func setAtomicIdx(idx: Int64): Unit {
        arena.putI64(idx, offset + 16)
    }
    
    public func getKey(): Array<Byte> {
        let keyOffset = getKeyOffset()
        let keySize = getKeySize()
        return arena.getBytes(keyOffset, keySize)
    }
    
    public func compareKey(other: Array<Byte>): Int64 {
        let keyOffset = getKeyOffset()
        let keySize = Int64(getKeySize())
        let otherSize = other.size
        let minLen = if (keySize < otherSize) { keySize } else { otherSize }
        
        if (minLen <= 0) {
            return Int64(keySize - otherSize)
        }
        
        // 短 key 用逐字节比较（避免 FFI 开销）
        if (minLen < 64) {
            let buf = arena.getBuf()
            let baseOffset = Int64(keyOffset)
            
            for (i in 0..minLen) {
                let b1 = buf[baseOffset + i]
                let b2 = other[i]
                if (b1 < b2) {
                    return -1
                } else if (b1 > b2) {
                    return 1
                }
            }
        } else {
            // 长 key 用 memcmp（SIMD 优化）
            let buf = arena.getBuf()
            let cmp = fastMemcmp(buf, Int64(keyOffset), other, 0, minLen)
            
            if (cmp != 0) {
                return Int64(cmp)
            }
        }
        
        return Int64(keySize - otherSize)
    }
    
    public func getKeyOffset(): UInt32 {
        return arena.getU32(offset + 8)
    }
    
    public func getKeySize(): UInt16 {
        return arena.getU16(offset + 12)
    }
    
    public func getHeight(): UInt16 {
        return arena.getU16(offset + 14)
    }
    
    public func getValue(): UInt64 {
        return atomicStorage.getValue(getAtomicIdx())
    }
    
    public func setValue(value: UInt64): Unit {
        atomicStorage.setValue(getAtomicIdx(), value)
    }
    
    public func getNextOffset(level: Int64): UInt32 {
        return atomicStorage.getNextOffset(getAtomicIdx(), level)
    }
    
    public func setNextOffset(level: Int64, nextOffset: UInt32): Unit {
        atomicStorage.setNextOffset(getAtomicIdx(), level, nextOffset)
    }
    
    public func casNextOffset(level: Int64, oldOffset: UInt32, newOffset: UInt32): Bool {
        return atomicStorage.casNextOffset(getAtomicIdx(), level, oldOffset, newOffset)
    }
}
