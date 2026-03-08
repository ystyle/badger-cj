/**
 * Skiplist Node 结构
 * 
 * Node 存储在 Arena 中，使用偏移量而非指针
 */
package badgercj.skiplist

import badgercj.arena.*

/**
 * Skiplist 节点
 * 
 * 内存布局（在 Arena 中）：
 * - value (UInt64): 高32位=value offset, 低32位=value size
 * - keyOffset (UInt32): Key 在 Arena 中的偏移量
 * - keySize (UInt16): Key 长度
 * - height (UInt16): 节点高度
 * - tower[height] (UInt32数组): 每层的下一个节点偏移量
 */
public class Node {
    private let arena: Arena
    private let offset: UInt32  // 节点在 Arena 中的偏移量
    
    public init(arena: Arena, offset: UInt32) {
        this.arena = arena
        this.offset = offset
    }
    
    /**
     * 获取节点在 Arena 中的偏移量
     */
    public func getOffset(): UInt32 {
        return offset
    }
    
    /**
     * 获取 Key
     */
    public func getKey(): Array<Byte> {
        let keyOffset = getKeyOffset()
        let keySize = getKeySize()
        return arena.getBytes(keyOffset, keySize)
    }
    
    /**
     * 获取 ValueStruct（offset + size）
     */
    public func getValue(): UInt64 {
        return arena.getU64(offset)
    }
    
    /**
     * 设置 ValueStruct
     */
    public func setValue(value: UInt64): Unit {
        arena.putU64(value, offset)
    }
    
    /**
     * 获取 Key 偏移量
     */
    public func getKeyOffset(): UInt32 {
        return arena.getU32(offset + 8)  // value(8) + keyOffset(4)
    }
    
    /**
     * 获取 Key 大小
     */
    public func getKeySize(): UInt16 {
        return arena.getU16(offset + 12)  // value(8) + keyOffset(4) + keySize(2)
    }
    
    /**
     * 获取节点高度
     */
    public func getHeight(): UInt16 {
        return arena.getU16(offset + 14)  // value(8) + keyOffset(4) + keySize(2) + height(2)
    }
    
    /**
     * 获取下一节点偏移量（指定层级）
     */
    public func getNextOffset(level: Int64): UInt32 {
        let towerOffset = offset + 16 + UInt32(level * 4)  // value(8) + keyOffset(4) + keySize(2) + height(2) + tower[level]
        return arena.getU32(towerOffset)
    }
    
    /**
     * 设置下一节点偏移量（指定层级）
     */
    public func setNextOffset(level: Int64, nextOffset: UInt32): Unit {
        let towerOffset = offset + 16 + UInt32(level * 4)
        arena.putU32(nextOffset, towerOffset)
    }
    
    /**
     * CAS 更新下一节点偏移量
     */
    public func casNextOffset(level: Int64, oldOffset: UInt32, newOffset: UInt32): Bool {
        // 仓颉的 Arena 没有 CAS 操作，需要使用外部锁
        // 简化实现：先比较，再设置
        let currentOffset = getNextOffset(level)
        if (currentOffset == oldOffset) {
            setNextOffset(level, newOffset)
            return true
        }
        return false
    }
}