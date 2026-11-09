package badgercj.table

import std.collection.*
import std.sync.*

// 块缓存（Block Cache）：Table 读路径上的一层按字节计费 LRU。
//
// 为什么需要：2.0 的 mmap 模式按需映射，每次读 block 都 memcpy + 分配新数组；
// 实测随机读比「整表驻留堆」慢 2.7-3.2x（128MB: 112.3 vs 35.5 us/Get）。
// 缓存把热 block 留在内存里，读延迟回到堆内模式水平，而容量上限显式可控。
//
// 键必须是 (tableId, blockIdx)：compaction 会生成新表（新 id），同 blockIdx 的
// 内容可能完全不同；摘表时按 tableId 整桶失效，避免读到旧表数据。
public class BlockCache {
    private let capacityBytes: Int64
    private let lock: Mutex
    private let entries: HashMap<UInt64, HashMap<Int64, CacheNode>>
    private var head: ?CacheNode
    private var tail: ?CacheNode
    private var usedBytes: Int64
    private var hitCount: Int64
    private var missCount: Int64

    public init(capacityBytes!: UInt64) {
        this.capacityBytes = Int64(capacityBytes)
        this.lock = Mutex()
        this.entries = HashMap<UInt64, HashMap<Int64, CacheNode>>()
        this.head = None
        this.tail = None
        this.usedBytes = 0
        this.hitCount = 0
        this.missCount = 0
    }

    public func used(): Int64 {
        synchronized(lock) {
            usedBytes
        }
    }

    public func hits(): Int64 {
        synchronized(lock) {
            hitCount
        }
    }

    public func misses(): Int64 {
        synchronized(lock) {
            missCount
        }
    }

    public func get(tableId: UInt64, blockIdx: Int64): ?Array<Byte> {
        synchronized(lock) {
            if (let Some(bucket) <- entries.get(tableId)) {
                if (let Some(node) <- bucket.get(blockIdx)) {
                    unlink(node)
                    linkFront(node)
                    hitCount++
                    return Some(node.data)
                }
            }
            missCount++
            return None
        }
    }

    public func put(tableId: UInt64, blockIdx: Int64, data: Array<Byte>): Unit {
        if (data.size == 0 || Int64(data.size) > capacityBytes) {
            return
        }
        synchronized(lock) {
            if (let Some(bucket) <- entries.get(tableId)) {
                if (bucket.contains(blockIdx)) {
                    // 同一 (tableId, blockIdx) 内容不可变；已存在直接返回
                    return
                }
            } else {
                entries[tableId] = HashMap<Int64, CacheNode>()
            }
            let node = CacheNode(tableId, blockIdx, data)
            entries[tableId][blockIdx] = node
            usedBytes += Int64(data.size)
            linkFront(node)
            while (usedBytes > capacityBytes) {
                match (tail) {
                    case Some(victim) =>
                        if (victim.tableId == node.tableId && victim.blockIdx == node.blockIdx) {
                            // 容量小到连刚插入的条目都放不下：放弃缓存该条，避免死循环
                            unlink(victim)
                            removeFromBucket(victim)
                            usedBytes -= Int64(victim.data.size)
                            return
                        }
                        evictTail()
                    case None => return
                }
            }
        }
    }

    public func invalidateTable(tableId: UInt64): Unit {
        synchronized(lock) {
            match (entries.get(tableId)) {
                case Some(bucket) =>
                    for (node in bucket.values()) {
                        unlink(node)
                        usedBytes -= Int64(node.data.size)
                    }
                    entries.remove(tableId)
                case None => ()
            }
        }
    }

    public func clear(): Unit {
        synchronized(lock) {
            entries.clear()
            head = None
            tail = None
            usedBytes = 0
        }
    }

    private func evictTail(): Unit {
        match (tail) {
            case Some(victim) =>
                unlink(victim)
                removeFromBucket(victim)
                usedBytes -= Int64(victim.data.size)
            case None => ()
        }
    }

    private func removeFromBucket(node: CacheNode): Unit {
        match (entries.get(node.tableId)) {
            case Some(bucket) =>
                bucket.remove(node.blockIdx)
                if (bucket.isEmpty()) {
                    entries.remove(node.tableId)
                }
            case None => ()
        }
    }

    private func linkFront(node: CacheNode): Unit {
        node.prev = None
        node.next = head
        match (head) {
            case Some(h) => h.prev = node
            case None => tail = node
        }
        head = node
    }

    private func unlink(node: CacheNode): Unit {
        match (node.prev) {
            case Some(p) => p.next = node.next
            case None => head = node.next
        }
        match (node.next) {
            case Some(n) => n.prev = node.prev
            case None => tail = node.prev
        }
        node.prev = None
        node.next = None
    }
}

class CacheNode {
    let tableId: UInt64
    let blockIdx: Int64
    let data: Array<Byte>
    var prev: ?CacheNode
    var next: ?CacheNode

    init(tableId: UInt64, blockIdx: Int64, data: Array<Byte>) {
        this.tableId = tableId
        this.blockIdx = blockIdx
        this.data = data
        this.prev = None
        this.next = None
    }
}
