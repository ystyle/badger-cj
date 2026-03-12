/**
 * Skiplist 并发跳表实现
 * 
 * 基于 Arena 的并发安全跳表
 * 支持 O(log n) 的查找和插入
 * 
 * 使用分离的 AtomicStorage 实现真正的无锁并发
 */
package badgercj.skiplist

import std.sync.*
import std.random.*
import badgercj.arena.*

private let HEIGHT_INCREASE: UInt32 = 1431655765u32

public class Skiplist {
    private let arena: Arena
    private let atomicStorage: AtomicStorage
    private let head: Node
    private let height: AtomicInt32
    private let random: Random
    
    public init(arena: Arena, atomicStorage: AtomicStorage) {
        this.arena = arena
        this.atomicStorage = atomicStorage
        this.height = AtomicInt32(1)
        this.random = Random()
        
        let headAtomicIdx = atomicStorage.allocNode()
        let headOffset = arena.putNode(MAX_HEIGHT)
        this.head = Node(arena, headOffset, atomicStorage)
        head.setAtomicIdx(headAtomicIdx)
        
        for (i in 0..MAX_HEIGHT) {
            head.setNextOffset(i, 0)
        }
    }
    
    private func randomHeight(): Int64 {
        var h: Int64 = 1
        
        while (h < MAX_HEIGHT && random.nextUInt32() <= HEIGHT_INCREASE) {
            h++
        }
        
        return h
    }
    
    public func getHeight(): Int64 {
        return Int64(height.load())
    }
    
    private func getNode(offset: UInt32): Node {
        Node(arena, offset, atomicStorage)
    }
    
    private func compareKeyAt(nodeOffset: UInt32, key: Array<Byte>): Int64 {
        let keyOffset = arena.getU32(nodeOffset + 8)
        let keySize = Int64(arena.getU16(nodeOffset + 12))
        let keyLen = key.size
        let minLen = if (keySize < keyLen) { keySize } else { keyLen }
        let buf = arena.getBuf()
        let baseOffset = Int64(keyOffset)
        
        for (i in 0..minLen) {
            let b1 = buf[baseOffset + i]
            let b2 = key[i]
            if (b1 < b2) {
                return -1
            } else if (b1 > b2) {
                return 1
            }
        }
        
        if (keySize < keyLen) {
            return -1
        } else if (keySize > keyLen) {
            return 1
        }
        return 0
    }
    
    private func getNextOffsetAt(nodeOffset: UInt32, level: Int64): UInt32 {
        let atomicIdx = arena.getI64(nodeOffset + 16)
        return atomicStorage.getNextOffset(atomicIdx, level)
    }
    
    public func get(key: Array<Byte>): ?Node {
        var x = head
        var level = getHeight() - 1
        
        while (level >= 0) {
            var nextOffset = x.getNextOffset(level)
            
            if (nextOffset == 0) {
                level--
                continue
            }
            
            let n = getNode(nextOffset)
            let cmp = compareKeys(key, n.getKey())
            
            if (cmp > 0) {
                x = n
            } else if (cmp == 0) {
                return Some(n)
            } else {
                level--
            }
        }
        
        None
    }
    
    public func findGe(key: Array<Byte>): ?Node {
        var x = head
        var level = getHeight() - 1
        
        while (level >= 0) {
            var nextOffset = x.getNextOffset(level)
            
            if (nextOffset == 0) {
                level--
                continue
            }
            
            let n = getNode(nextOffset)
            let cmp = compareKeys(key, n.getKey())
            
            if (cmp > 0) {
                x = n
            } else if (cmp == 0) {
                return Some(n)
            } else {
                level--
            }
        }
        
        let finalNext = x.getNextOffset(0)
        if (finalNext == 0) {
            return None
        }
        Some(getNode(finalNext))
    }
    
    public func add(key: Array<Byte>, value: UInt64): Unit {
        let h = randomHeight()
        
        while (true) {
            let currentHeight = height.load()
            if (h <= Int64(currentHeight)) {
                break
            }
            if (height.compareAndSwap(currentHeight, Int32(h))) {
                break
            }
        }
        
        var prevOffsets = Array<UInt32>(MAX_HEIGHT, repeat: head.getOffset())
        var nextOffsets = Array<UInt32>(MAX_HEIGHT, repeat: 0u32)
        
        let listHeight = getHeight()
        var xOff = head.getOffset()
        var level = listHeight - 1
        
        while (level >= 0) {
            var nextOffset = getNextOffsetAt(xOff, level)
            
            while (nextOffset != 0) {
                let cmp = compareKeyAt(nextOffset, key)
                
                if (cmp > 0) {
                    xOff = nextOffset
                    nextOffset = getNextOffsetAt(xOff, level)
                } else if (cmp == 0) {
                    let n = getNode(nextOffset)
                    n.setValue(value)
                    return
                } else {
                    break
                }
            }
            
            prevOffsets[level] = xOff
            nextOffsets[level] = nextOffset
            level--
        }
        
        let atomicIdx = atomicStorage.allocNode()
        let nodeOffset = arena.putNode(h)
        let newNode = Node(arena, nodeOffset, atomicStorage)
        newNode.setAtomicIdx(atomicIdx)
        
        let keyOffset = arena.putBytes(key)
        
        newNode.setValue(value)
        arena.putU32(keyOffset, nodeOffset + 8)
        arena.putU16(UInt16(key.size), nodeOffset + 12)
        arena.putU16(UInt16(h), nodeOffset + 14)
        
        for (i in 0..h) {
            newNode.setNextOffset(i, nextOffsets[i])
            
            while (true) {
                let prevOff = prevOffsets[i]
                let prevNode = getNode(prevOff)
                
                if (prevNode.casNextOffset(i, nextOffsets[i], nodeOffset)) {
                    break
                }
                
                let (p, n) = findSpliceForLevel(key, prevOff, i)
                prevOffsets[i] = p
                nextOffsets[i] = n
                
                if (p == n && p != 0u32) {
                    let existingNode = getNode(p)
                    existingNode.setValue(value)
                    return
                }
                
                newNode.setNextOffset(i, n)
            }
        }
    }
    
    private func findSpliceForLevel(key: Array<Byte>, before: UInt32, level: Int64): (UInt32, UInt32) {
        var prev = before
        var next: UInt32 = 0
        var found = false
        
        while (!found) {
            let prevNode = getNode(prev)
            next = prevNode.getNextOffset(level)
            
            if (next == 0) {
                return (prev, 0u32)
            }
            
            let nextNode = getNode(next)
            let cmp = nextNode.compareKey(key)
            
            if (cmp == 0) {
                return (next, next)
            }
            if (cmp > 0) {
                return (prev, next)
            }
            prev = next
        }
        return (prev, next)
    }
    
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
    
    public func getArena(): Arena {
        return arena
    }
    
    public func getHead(): Node {
        return head
    }
    
    public func getAtomicStorage(): AtomicStorage {
        return atomicStorage
    }
}
