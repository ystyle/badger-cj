/**
 * AtomicStorage - 原子存储管理
 * 
 * 管理节点的 value 和 tower 数组
 * 使用 atomic 类型确保并发安全
 */
package badgercj.skiplist

import std.sync.*
import badgercj.arena.*  // 导入 MAX_HEIGHT

public class AtomicStorage {
    private let values: Array<AtomicUInt64>
    private let towers: Array<Array<AtomicUInt32>>
    private let nodeCount: AtomicInt64
    public let capacity: Int64
    
    public init(capacity: Int64) {
        this.capacity = capacity
        this.nodeCount = AtomicInt64(0)
        this.values = Array<AtomicUInt64>(capacity, { _ => AtomicUInt64(0) })
        this.towers = Array<Array<AtomicUInt32>>(capacity, { _ => 
            Array<AtomicUInt32>(MAX_HEIGHT, { _ => AtomicUInt32(0) })
        })
    }
    
    public func allocNode(): Int64 {
        let idx = nodeCount.fetchAdd(1)
        if (idx >= capacity) {
            throw Exception("AtomicStorage overflow: capacity ${capacity}")
        }
        return idx
    }
    
    public func getValue(nodeIdx: Int64): UInt64 {
        return values[nodeIdx].load()
    }
    
    public func setValue(nodeIdx: Int64, value: UInt64): Unit {
        values[nodeIdx].store(value)
    }
    
    public func getNextOffset(nodeIdx: Int64, level: Int64): UInt32 {
        return towers[nodeIdx][level].load()
    }
    
    public func setNextOffset(nodeIdx: Int64, level: Int64, offset: UInt32): Unit {
        towers[nodeIdx][level].store(offset)
    }
    
    public func casNextOffset(nodeIdx: Int64, level: Int64, old: UInt32, new: UInt32): Bool {
        return towers[nodeIdx][level].compareAndSwap(old, new)
    }
    
    public func getNodeCount(): Int64 {
        return nodeCount.load()
    }
}
