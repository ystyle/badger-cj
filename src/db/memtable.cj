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
    // 异步 flusher 完成标志：落盘 + addTable + imm 出队后由 db 置位（dequeueFlushed）。
    // 供 flushMemTable() 精确等待"本表已持久可读"（水位等待无法区分队列中其它表
    // 的出队，会提前返回）。
    private let flushDone: AtomicBool
    
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
        this.flushDone = AtomicBool(false)
        
        if (opt.DisableWAL) {
            this.wal = None
        } else {
            let walPath = opt.Dir + "/${fid}.mem"
            // v2.0：WAL 走 mmap（预分配 = arena 大小，保证 WAL 不会先于 arena 满）；
            // Config.MmapWAL=false 时回退 v1.x 的 BufferedOutputStream 路径
            this.wal = Some(WAL.open(walPath, capacity: arenaSize, useMmap: opt.MmapWAL))
        }
        
        if (walExists && !opt.DisableWAL) {
            replaying.store(true)
            this.wal?.replay(this)
            replaying.store(false)
        }
    }
    
    /**
     * 标记进入/退出恢复期。恢复期内的写入不再回写 WAL —— 数据本就来自 WAL，
     * 重写既冗余又受 WAL 预分配容量限制（残留 WAL 可能大于本 memtable 的容量）。
     */
    protected func beginReplay(): Unit {
        replaying.store(true)
    }

    protected func endReplay(): Unit {
        replaying.store(false)
    }

    public func put(key: Array<Byte>, vs: ValueStruct): Unit {
        let encoded = vs.encode()
        
        // arena 预检必须在 WAL 写入之前：否则失败事务的数据会残留 WAL，崩溃后 replay
        // 把"失败数据"复活并再次抛异常（评审 P1-1）。大小上限由写入路径统一管控：
        // prepareEntries 校验 key ≤ 65000、value ≤ vlog 上限并按 ValueThreshold 分流，
        // ≥ 阈值走 vlog（对齐 badger-go）——内联条目不再有 64KB 编码限制（value 槽 32 位）
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
        let size = UInt32(encoded.size)
        
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
            let size = UInt32(value & 0xFFFFFFFFu64)
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
                    let size = UInt32(value & 0xFFFFFFFFu64)
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
    
    // memtable 唯一标识（文件/WAL id）：imm 内不重复（open 恢复表来自不同 .mem，
    // 运行期轮换表经 reserveFileID 单调分配）。用于 flusher 按对象出队定位
    // （仓颉类无引用相等比较，== 需要 Equatable）。
    public func getFid(): Int64 {
        fid
    }
    
    // 异步 flush 完成标志（db.dequeueFlushed 置位；仅前进一次，重试不重置）
    public func markFlushDone(): Unit {
        flushDone.store(true)
    }
    
    public func isFlushDone(): Bool {
        flushDone.load()
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
            let size = UInt32(value & 0xFFFFFFFFu64)
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
