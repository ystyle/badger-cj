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
protected class MemTable {
    private let opt: Config
    private let fid: Int64
    private let table: Skiplist
    private let arena: Arena
    private let atomicStorage: AtomicStorage
    private let refs: AtomicInt32
    private let walExists: Bool
    private let sizeInBytes_: AtomicUInt64
    private let wal: ?WAL
    private let replaying: AtomicBool
    private let maxVersion: AtomicUInt64
    
    protected init(opt: Config, fid: Int64, walExists: Bool) {
        this.opt = opt
        this.fid = fid
        this.walExists = walExists
        
        let arenaSize = Int64(opt.MemTableSize * 2)
        this.arena = Arena(arenaSize)
        
        let estimatedEntries = arenaSize / 256
        let initialCapacity = if (estimatedEntries > 65536) { 65536 } else { estimatedEntries }
        this.atomicStorage = AtomicStorage(initialCapacity)
        this.table = Skiplist(arena, atomicStorage)
        this.refs = AtomicInt32(1)
        this.sizeInBytes_ = AtomicUInt64(0)
        this.replaying = AtomicBool(false)
        this.maxVersion = AtomicUInt64(0)
        
        if (opt.DisableWAL) {
            this.wal = None
        } else {
            let walPath = opt.Dir + "/${fid}.mem"
            this.wal = Some(WAL.open(walPath))
        }
        
        if (walExists && !opt.DisableWAL) {
            replaying.store(true)
            this.wal?.replay(this)
            replaying.store(false)
        }
    }
    
    public func put(key: Array<Byte>, vs: ValueStruct): Unit {
        let encoded = vs.encode()
        
        // 64KB 上限检查与 arena 预检必须提前到 WAL 写入之前：
        // 否则失败事务的数据会残留 WAL，崩溃后 replay 把"失败数据"复活并再次抛异常
        // （评审 P1-1：此前顺序为 encode → WAL 写 → 64KB 检查抛错 → 重启必崩）
        if (encoded.size > 65535) {
            throw Exception("ValueStruct encoded size exceeds UInt16 max: ${encoded.size}")
        }
        let remaining = Int64(arena.size) - Int64(arena.usedSize())
        if (Int64(encoded.size) > remaining) {
            throw Exception("Arena overflow: requested ${encoded.size}, remaining ${remaining}")
        }
        
        if (!opt.DisableWAL && !replaying.load()) {
            if (let Some(w) <- wal) {
                w.write(key, encoded)
                if (opt.SyncWrites) {
                    w.sync()
                }
            }
        }
        
        if (vs.version > maxVersion.load()) {
            maxVersion.store(vs.version)
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
            let size = UInt32(value & 0xFFFFu64)
            let encoded = arena.getBytes(offset, size)
            return ValueStruct.decode(encoded)
        }
        None
    }
    
    public func getWithTs(userKey: Array<Byte>, readTs: UInt64): ?ValueStruct {
        let seekKey = keyWithTs(userKey, readTs)
        
        let node = table.findGe(seekKey)
        if (let Some(n) <- node) {
            let key = n.getKey()
            if (sameKey(key, seekKey)) {
                let ts = parseTs(key)
                if (ts <= readTs) {
                    let value = n.getValue()
                    let offset = UInt32(value >> 32)
                    let size = UInt32(value & 0xFFFFu64)
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
            this.wal?.delete()
        }
    }
    
    public func closeWAL(): Unit {
        this.wal?.close()
    }
    
    public func flushWAL(): Unit {
        this.wal?.flush()
    }
    
    public func iterator(): SkipIterator {
        return SkipIterator(table)
    }
    
    public func isEmpty(): Bool {
        table.getHead().getNextOffset(0) == 0
    }
    
    public func deleteWAL(): Unit {
        this.wal?.delete()
    }
    
    public func getMaxVersion(): UInt64 {
        maxVersion.load()
    }
    
    public func getTable(): Skiplist {
        table
    }
}

/**
 * SkipIterator - MemTable 迭代器
 */
public class SkipIterator {
    private let table: Skiplist
    private let atomicStorage: AtomicStorage
    private var current: ?Node
    
    protected init(table: Skiplist) {
        this.table = table
        this.atomicStorage = table.getAtomicStorage()
        this.current = None
        
        let head = table.getHead()
        let firstOffset = head.getNextOffset(0)
        if (firstOffset != 0) {
            current = Some(Node(table.getArena(), firstOffset, atomicStorage))
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
            let size = UInt32(value & 0xFFFFu64)
            let encoded = table.getArena().getBytes(offset, size)
            let vs = ValueStruct.decode(encoded)
            
            let nextOffset = node.getNextOffset(0)
            if (nextOffset != 0) {
                current = Some(Node(table.getArena(), nextOffset, atomicStorage))
            } else {
                current = None
            }
            
            return Some((key, vs))
        }
        None
    }
}
