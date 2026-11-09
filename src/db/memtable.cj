package badgercj.db

import std.sync.*
import std.collection.*
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
    
    // arenaBytes：可选的 arena 容量覆盖（Pebble 式渐进扩容用）。0 = 用 go 公式的目标值；
    // 传入更小值时按传入值分配（memtable 用满后靠 shouldFlush 轮换，见下）。
    protected init(opt: Config, fid: Int64, walExists: Bool, arenaBytes!: Int64 = 0) {
        this.opt = opt
        this.fid = fid
        this.walExists = walExists
        
        // arena 大小对齐 badger-go 的 arenaSize()：
        //   MemTableSize + maxBatchSize + maxBatchCount*MaxNodeSize
        // 旧实现固定 2x MemTableSize，导致每个 memtable 的堆占用约为 go 的 2 倍
        // （默认 64MB 时单个 arena 就是 128MB，NumMemtables=5 的背压上限下峰值可达
        //  约 640MB）。多出来的那部分预留是给「一批写入的 skiplist 节点开销」的，
        // 公式里的 maxBatchSize/maxBatchCount 已经覆盖，不需要 2 倍。
        var maxBatchSize = Int64(opt.MemTableSize) * 15 / 100
        if (maxBatchSize < 1024) {
            maxBatchSize = 1024
        }
        var maxBatchCount = maxBatchSize / 96
        if (maxBatchCount < 1) {
            maxBatchCount = 1
        }
        let targetArenaSize = Int64(opt.MemTableSize) + maxBatchSize + maxBatchCount * MAX_NODE_SIZE
        let arenaSize = if (arenaBytes > 0 && arenaBytes < targetArenaSize) {
            arenaBytes
        } else {
            targetArenaSize
        }
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
            // v2.0：WAL 走 mmap（预分配 = 2x MemTableSize，对齐 go 的 WAL 段容量；
            // 与 arena 大小解耦——arena 只按「memtable 能装多少」算，WAL 段还要容纳
            // 换段前最后一批写入，保持 2 倍余量）；
            // Config.MmapWAL=false 时回退 v1.x 的 BufferedOutputStream 路径
            this.wal = Some(WAL.open(walPath, capacity: Int64(opt.MemTableSize * 2), useMmap: opt.MmapWAL))
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
    
    /**
     * 批量写入（分组提交）：整批一次 WAL 追加 + 一次 sync（SyncWrites），再逐条进 skiplist。
     *
     * 从 `start` 起尽量多写，遇到「落盘阈值」或「arena 余量不足」即停，返回写入条数；
     * 调用方持 db 写锁，返回 0 表示本表连一条都放不下（需由调用方轮换 memtable）。
     * 语义与逐条 `put` 等价：arena 预检、WAL 顺序、maxVersion、sizeInBytes 统计一致。
     */
    public func putBatch(entries: ArrayList<(Array<Byte>, ValueStruct)>, start: Int64): Int64 {
        if (start >= entries.size) {
            return 0
        }
        let encodedList = ArrayList<Array<Byte>>()
        var totalReserved: Int64 = 0
        var accepted: Int64 = 0
        var projectedData = Int64(sizeInBytes_.load())
        let threshold = Int64(opt.MemTableSize)
        var i = start
        while (i < entries.size) {
            // 与逐条 put 的轮换语义对齐：本条之前的表已达阈值时不再接收（由调用方先轮换）
            if (accepted > 0 && projectedData >= threshold) {
                break
            }
            let (key, vs) = entries[i]
            let enc = vs.encode()
            let encSize = Int64(enc.size)
            // arena 用量除「值编码 + key」外还有 skiplist 节点（含塔层 + 对齐）——
            // 按最坏节点大小预留，避免批量写入到一半 arena.putNode 抛溢出（那样 WAL 已写、
            // 条目却进不了 skiplist，失败事务的数据会在崩溃 replay 时被复活）。
            let reserve = encSize + Int64(key.size) + MAX_NODE_SIZE + NODE_ALIGN + 8
            let remaining = Int64(arena.size) - Int64(arena.usedSize()) - totalReserved
            if (reserve > remaining) {
                break
            }
            encodedList.add(enc)
            totalReserved += reserve
            projectedData += encSize + Int64(key.size)
            accepted++
            i++
        }
        if (accepted == 0) {
            return 0
        }
        
        if (!opt.DisableWAL && !replaying.load()) {
            if (let Some(w) <- wal) {
                let keys = ArrayList<Array<Byte>>()
                let values = ArrayList<Array<Byte>>()
                for (j in 0..accepted) {
                    keys.add(entries[start + j][0])
                    values.add(encodedList[j])
                }
                // 整批一次映射写 + 一次 sync（分组提交：N 个提交共享一次 msync）
                w.writeBatch(keys, values)
                if (opt.SyncWrites) {
                    w.sync()
                }
            }
        }
        
        for (j in 0..accepted) {
            let (key, vs) = entries[start + j]
            let enc = encodedList[j]
            if (vs.version > maxVersion.load()) {
                maxVersion.store(vs.version)
            }
            let offset = arena.putBytes(enc)
            let value = (UInt64(offset) << 32) | UInt64(UInt32(enc.size))
            table.add(key, value)
            sizeInBytes_.fetchAdd(UInt64(key.size + enc.size))
        }
        accepted
    }
    
    /** memtable 剩余 arena 字节（写入路径分段用）。 */
    public func remainingArena(): Int64 {
        Int64(arena.size) - Int64(arena.usedSize())
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
    
    // 对齐 badger-go：按 **arena 已用量** 判断（go: MemSize() >= MemTableSize），
    // 而不是按用户数据字节数。原因：arena 里还有 skiplist 节点（塔层 + 对齐），小 value
    // 时节点开销可与数据本身相当甚至更大；只有按 arena 用量判断，arena 的
    // 「MemTableSize + 一批预留」公式才成立（按数据判断会在 arena 耗尽后才触发）。
    public func shouldFlush(): Bool {
        // 主判据对齐 go：arena 已用 >= MemTableSize；
        // 兜底：渐进扩容的小 arena 可能小于 MemTableSize（前几张表），用满即轮换，
        // 否则剩余空间不足以容纳下一批 worst-case 预留，写入会停摆。
        if (UInt64(arena.usedSize()) >= opt.MemTableSize) {
            return true
        }
        return Int64(arena.usedSize()) >= Int64(arena.size) * 95 / 100
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
