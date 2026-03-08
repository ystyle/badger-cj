/**
 * Skiplist 并发跳表实现
 * 
 * 基于 Arena 的并发安全跳表
 * 支持 O(log n) 的查找和插入
 */
package badgercj.skiplist

import std.sync.*
import std.random.*
import badgercj.arena.*

// Skiplist 常量
private let HEIGHT_INCREASE: UInt32 = 1431655765u32  // UInt32.Max / 3 ≈ 1/3 概率

/**
 * Skiplist 并发跳表
 */
public class Skiplist {
    // Arena 内存池
    private let arena: Arena
    
    // 头节点
    private let head: Node
    
    // 当前最大高度
    private let height: AtomicInt32
    
    // 随机数生成器
    private let random: Random
    
    public init(arena: Arena) {
        this.arena = arena
        this.height = AtomicInt32(1)
        this.random = Random()
        
        // 创建头节点（高度 = MAX_HEIGHT）
        let headOffset = arena.putNode(MAX_HEIGHT)
        this.head = Node(arena, headOffset)
        
        // 初始化头节点的 tower 为 0（null）
        for (i in 0..MAX_HEIGHT) {
            head.setNextOffset(i, 0)
        }
    }
    
    /**
     * 生成随机高度
     */
    private func randomHeight(): Int64 {
        var h: Int64 = 1
        
        while (h < MAX_HEIGHT && random.nextUInt32() <= HEIGHT_INCREASE) {
            h++
        }
        
        return h
    }
    
    /**
     * 获取当前高度
     */
    public func getHeight(): Int64 {
        return Int64(height.load())
    }
    
    /**
     * 查找节点
     * 
     * 返回：找到返回节点，未找到返回 None
     */
    public func get(key: Array<Byte>): ?Node {
        // 从最高层开始查找
        var x = head
        var level = getHeight() - 1
        
        while (level >= 0) {
            // 获取下一节点
            let nextOffset = x.getNextOffset(level)
            
            if (nextOffset == 0) {
                // 没有下一节点，下降一层
                level--
                continue
            }
            
            let n = Node(arena, nextOffset)
            let cmp = compareKeys(key, n.getKey())
            
            if (cmp > 0) {
                // key > node.key，继续向右
                x = n
            } else if (cmp == 0) {
                // 找到
                return Some(n)
            } else {
                // key < node.key，下降一层
                level--
            }
        }
        
        // 未找到
        None
    }
    
    /**
     * 插入节点
     * 
     * 如果 key 已存在，更新 value
     */
    public func add(key: Array<Byte>, value: UInt64): Unit {
        // 生成随机高度
        let h = randomHeight()
        
        // 更新全局高度
        while (true) {
            let currentHeight = height.load()
            if (h <= Int64(currentHeight)) {
                break
            }
            if (height.compareAndSwap(currentHeight, Int32(h))) {
                break
            }
        }
        
        // 查找插入位置
        var prev = Array<Node>(MAX_HEIGHT, repeat: head)
        var next = Array<UInt32>(MAX_HEIGHT, repeat: 0)
        
        var x = head
        var level = getHeight() - 1
        
        while (level >= 0) {
            // 查找第 level 层的插入位置
            var nextOffset = x.getNextOffset(level)
            
            while (nextOffset != 0) {
                let n = Node(arena, nextOffset)
                let cmp = compareKeys(key, n.getKey())
                
                if (cmp > 0) {
                    x = n
                    nextOffset = x.getNextOffset(level)
                } else if (cmp == 0) {
                    // key 已存在，更新 value
                    n.setValue(value)
                    return
                } else {
                    break
                }
            }
            
            prev[level] = x
            next[level] = nextOffset
            level--
        }
        
        // 分配新节点
        let nodeOffset = arena.putNode(h)
        let newNode = Node(arena, nodeOffset)
        
        // 存储 key
        let keyOffset = arena.putBytes(key)
        let keySize = UInt16(key.size)
        
        // 设置节点字段
        newNode.setValue(value)
        arena.putU32(keyOffset, nodeOffset + 8)
        arena.putU16(keySize, nodeOffset + 12)
        arena.putU16(UInt16(h), nodeOffset + 14)
        
        // 逐层插入（从底层到顶层）
        for (i in 0..h) {
            newNode.setNextOffset(i, next[i])
            prev[i].setNextOffset(i, nodeOffset)
        }
    }
    
    /**
     * 比较两个 key
     */
    private func compareKeys(a: Array<Byte>, b: Array<Byte>): Int64 {
        let minLen = if (a.size < b.size) { a.size } else { b.size }
        
        for (i in 0..minLen) {
            if (a[i] < b[i]) {
                return -1
            } else if (a[i] > b[i]) {
                return 1
            }
        }
        
        if (a.size < b.size) {
            return -1
        } else if (a.size > b.size) {
            return 1
        }
        
        return 0
    }
    
    /**
     * 获取 Arena
     */
    public func getArena(): Arena {
        return arena
    }
    
    /**
     * 获取头节点
     */
    public func getHead(): Node {
        return head
    }
}