package badgercj.db

import std.sync.*
import badgercj.skiplist.*
import badgercj.arena.*
import badgercj.table.*

/**
 * MemTable - 内存表
 * 
 * 基于 Skiplist 的内存 KV 存储
 */
public class MemTable {
    private let opt: DBOptions
    private let fid: Int64
    private let table: Skiplist
    private let arena: Arena
    private let refs: AtomicInt32
    private let walExists: Bool
    private let sizeInBytes_: AtomicUInt64
    private let wal: WAL
    private let replaying: AtomicBool
    private let maxVersion: AtomicUInt64
    
    public init(opt: DBOptions, fid: Int64, walExists: Bool) {
        this.opt = opt
        this.fid = fid
        this.walExists = walExists
        
        let arenaSize = Int64(opt.MemTableSize * 2)
        this.arena = Arena(arenaSize)
        this.table = Skiplist(arena)
        this.refs = AtomicInt32(1)
        this.sizeInBytes_ = AtomicUInt64(0)
        this.replaying = AtomicBool(false)
        this.maxVersion = AtomicUInt64(0)
        
        let walPath = opt.Dir + "/${fid}.mem"
        this.wal = WAL.open(walPath)
        
        if (walExists) {
            replaying.store(true)
            this.wal.replay(this)
            replaying.store(false)
        }
    }
    
    public func put(key: Array<Byte>, vs: ValueStruct): Unit {
        if (!opt.DisableWAL && !replaying.load()) {
            wal.write(key, vs)
        }
        
        if (vs.version > maxVersion.load()) {
            maxVersion.store(vs.version)
        }
        
        let encoded = vs.encode()
        if (encoded.size > 65535) {
            throw Exception("ValueStruct encoded size exceeds UInt16 max: ${encoded.size}")
        }
        let offset = arena.putBytes(encoded)
        let size = UInt16(encoded.size)
        
        let value = (UInt64(offset) << 32) | UInt64(size)
        table.add(key, value)
        
        let entrySize = UInt64(key.size + encoded.size)
        sizeInBytes_.fetchAdd(entrySize)
    }
    
    public func get(key: Array<Byte>): ?ValueStruct {
        let node = table.get(key)
        if (let Some(n) <- node) {
            let value = n.getValue()
            let offset = UInt32(value >> 32)
            let size = UInt16(value & 0xFFFFu64)
            let encoded = arena.getBytes(offset, size)
            return ValueStruct.decode(encoded)
        }
        None
    }
    
    public func getWithTs(userKey: Array<Byte>, readTs: UInt64): ?ValueStruct {
        let seekKey = keyWithTs(userKey, readTs)
        
        // 用 findGe 找 >= seekKey 的节点 (类似 Go 的 findNear)
        let node = table.findGe(seekKey)
        if (let Some(n) <- node) {
            let key = n.getKey()
            // 只比较 userKey，忽略时间戳
            if (sameKey(key, seekKey)) {
                let ts = parseTs(key)
                if (ts <= readTs) {
                    let value = n.getValue()
                    let offset = UInt32(value >> 32)
                    let size = UInt16(value & 0xFFFFu64)
                    let encoded = arena.getBytes(offset, size)
                    return ValueStruct.decode(encoded)
                }
            }
        }
        
        None
    }
    
    public func sizeInBytes(): UInt64 {
        return sizeInBytes_.load()
    }
    
    public func shouldFlush(): Bool {
        let dataSize = sizeInBytes()
        let arenaUsed = UInt64(arena.usedSize())
        let arenaSize = UInt64(arena.size)
        
        if (dataSize >= opt.MemTableSize) {
            return true
        }
        
        if (arenaUsed > arenaSize * 75 / 100) {
            return true
        }
        
        return false
    }
    
    public func incrRef(): Unit {
        refs.fetchAdd(1)
    }
    
    public func decrRef(): Unit {
        let old = refs.fetchSub(1)
        if (old == 1) {
            wal.delete()
        }
    }
    
    public func closeWAL(): Unit {
        wal.close()
    }
    
    public func flushWAL(): Unit {
        wal.flush()
    }
    
    public func iterator(): SkipIterator {
        return SkipIterator(table)
    }
    
    public func isEmpty(): Bool {
        table.getHead().getNextOffset(0) == 0
    }
    
    public func deleteWAL(): Unit {
        wal.delete()
    }
    
    public func getMaxVersion(): UInt64 {
        maxVersion.load()
    }
}

/**
 * SkipIterator - MemTable 迭代器
 */
public class SkipIterator {
    private let table: Skiplist
    private var current: ?Node
    
    public init(table: Skiplist) {
        this.table = table
        this.current = None
        
        let head = table.getHead()
        let firstOffset = head.getNextOffset(0)
        if (firstOffset != 0) {
            current = Some(Node(table.getArena(), firstOffset))
        }
    }
    
    public func hasNext(): Bool {
        if (let Some(node) <- current) {
            return true
        }
        return false
    }
    
    public func next(): ?(Array<Byte>, ValueStruct) {
        if (let Some(node) <- current) {
            let key = node.getKey()
            let value = node.getValue()
            let offset = UInt32(value >> 32)
            let size = UInt16(value & 0xFFFFu64)
            let encoded = table.getArena().getBytes(offset, size)
            let vs = ValueStruct.decode(encoded)
            
            let nextOffset = node.getNextOffset(0)
            if (nextOffset != 0) {
                current = Some(Node(table.getArena(), nextOffset))
            } else {
                current = None
            }
            
            return Some((key, vs))
        }
        None
    }
}
