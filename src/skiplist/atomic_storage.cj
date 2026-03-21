/**
 * AtomicStorage - 原子存储管理（分段扩展版本）
 * 
 * 管理节点的 value 和 tower 数组
 * 使用分段扩展避免预分配大量对象
 */
package badgercj.skiplist

import std.sync.*
import std.collection.*
import badgercj.arena.*

private const SEGMENT_SIZE: Int64 = 8192

class Segment {
    public let values: Array<AtomicUInt64>
    public let towers: Array<AtomicUInt32>
    
    // 注意：不能使用 repeat: AtomicUInt64(0)，因为 AtomicUInt64/AtomicUInt32 是引用类型
    // repeat 会创建值拷贝，导致所有元素共享同一个原子对象，造成并发问题
    public init() {
        this.values = Array<AtomicUInt64>(SEGMENT_SIZE, { _ => AtomicUInt64(0) })
        this.towers = Array<AtomicUInt32>(SEGMENT_SIZE * MAX_HEIGHT, { _ => AtomicUInt32(0) })
    }
}

protected class AtomicStorage {
    private let segments: ArrayList<Segment>
    private let segmentLock: Mutex
    private let nodeCount: AtomicInt64
    public let capacity: AtomicInt64
    
    public init(initialCapacity: Int64) {
        this.segments = ArrayList<Segment>()
        this.segmentLock = Mutex()
        this.nodeCount = AtomicInt64(0)
        this.capacity = AtomicInt64(0)
        
        let numSegments = (initialCapacity + SEGMENT_SIZE - 1) / SEGMENT_SIZE
        if (numSegments < 1) {
            addSegment()
        } else {
            for (_ in 0..numSegments) {
                addSegment()
            }
        }
    }
    
    private func addSegment(): Unit {
        segments.add(Segment())
        capacity.fetchAdd(SEGMENT_SIZE)
    }
    
    private func ensureCapacity(needed: Int64): Unit {
        while (needed >= capacity.load()) {
            segmentLock.lock()
            if (needed >= capacity.load()) {
                addSegment()
            }
            segmentLock.unlock()
        }
    }
    
    public func allocNode(): Int64 {
        let idx = nodeCount.fetchAdd(1)
        ensureCapacity(idx)
        return idx
    }
    
    private func getSegment(nodeIdx: Int64): Segment {
        let segIdx = nodeIdx / SEGMENT_SIZE
        return segments[segIdx]
    }
    
    private func getLocalIdx(nodeIdx: Int64): Int64 {
        return nodeIdx % SEGMENT_SIZE
    }
    
    public func getValue(nodeIdx: Int64): UInt64 {
        let seg = getSegment(nodeIdx)
        let localIdx = getLocalIdx(nodeIdx)
        return seg.values[localIdx].load()
    }
    
    public func setValue(nodeIdx: Int64, value: UInt64): Unit {
        let seg = getSegment(nodeIdx)
        let localIdx = getLocalIdx(nodeIdx)
        seg.values[localIdx].store(value)
    }
    
    public func getNextOffset(nodeIdx: Int64, level: Int64): UInt32 {
        let seg = getSegment(nodeIdx)
        let localIdx = getLocalIdx(nodeIdx)
        return seg.towers[localIdx * MAX_HEIGHT + level].load()
    }
    
    public func setNextOffset(nodeIdx: Int64, level: Int64, offset: UInt32): Unit {
        let seg = getSegment(nodeIdx)
        let localIdx = getLocalIdx(nodeIdx)
        seg.towers[localIdx * MAX_HEIGHT + level].store(offset)
    }
    
    public func casNextOffset(nodeIdx: Int64, level: Int64, old: UInt32, new: UInt32): Bool {
        let seg = getSegment(nodeIdx)
        let localIdx = getLocalIdx(nodeIdx)
        return seg.towers[localIdx * MAX_HEIGHT + level].compareAndSwap(old, new)
    }
    
    public func getNodeCount(): Int64 {
        return nodeCount.load()
    }
}