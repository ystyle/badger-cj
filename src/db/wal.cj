package badgercj.db

import std.fs.*
import std.io.*
import std.sync.*
import std.collection.*
import std.time.*
import badgercj.vlog.*
import badgercj.table.*
import mmapcj.*

/**
 * WAL（memtable 的 write-ahead log）。
 *
 * v2.0 起有两种后端（由 `Config.MmapWAL` 选择）：
 *
 * - **mmap（默认）**：每个段按 `capacity` 预分配并建立**段内固定映射**，`write` 直接把编码
 *   结果 memcpy 进映射区，`sync` 走 `msync`；段写满即**换段**（新开 `${fid}.mem.N`），
 *   段内不做运行中 remap——go badger 的 `Truncate + remap` 自述存在段错误窗口
 *   （memtable.go:417），此处从设计上规避。
 * - **buffered（回退）**：`File + BufferedOutputStream(64KB)`，v1.x 语义；`capacity <= 0`
 *   或 `Config.MmapWAL=false` 时启用，文件随写入增长、不换段。
 *
 * 段命名：第 0 段 = `<fid>.mem`（主段，外部按此名识别），第 N 段 = `<fid>.mem.N`。
 * 读取按段序拼接，恢复语义与单文件一致：每段解析到第一个坏条目即止。
 *
 * 崩溃一致性两种后端一致：未 sync 时页面/缓冲写回顺序不可控，恢复依赖 `LogEntry` 的 CRC
 * 校验 + 尾部截断（`readAll` 解析到第一个校验失败即停），与写方式无关。mmap 后端额外消除了
 * 缓冲后端"缓冲未满不落盘"的不确定窗口——映射页由内核按节奏写回。
 */
public class WAL {
    private let pathStr: String
    private let capacity: Int64
    private var mmap: ?MmapFile
    private var file: ?File
    private var buf: ?BufferedOutputStream<File>
    private var writeOffset: Int64
    /** 当前段序号：0 = 主段 `<path>`，N = `<path>.N` */
    private var segIndex: Int64
    private let lock: Mutex

    private init(path: String, capacity: Int64) {
        this.pathStr = path
        this.capacity = capacity
        this.mmap = None
        this.file = None
        this.buf = None
        this.writeOffset = 0
        this.segIndex = 0
        this.lock = Mutex()
    }

    // ---------------- 段管理 ----------------

    /** 第 index 段的路径：0 为主段（外部约定名），其余带 `.N` 后缀。 */
    private static func segmentPath(base: String, index: Int64): String {
        if (index == 0) {
            return base
        }
        return "${base}.${index}"
    }

    /**
     * 已存在的段序号（升序、连续）。
     * 段号由本类单调递增地创建，删除也总是整体删除，因此遇到第一个空缺即可停止扫描。
     */
    private static func scanSegments(base: String): ArrayList<Int64> {
        let result = ArrayList<Int64>()
        if (!exists(Path(base))) {
            return result
        }
        result.add(0)
        var i: Int64 = 1
        while (exists(Path(segmentPath(base, i)))) {
            result.add(i)
            i += 1
        }
        return result
    }

    /** 打开一段用于写入（mmap 模式）：映射大小取 max(capacity, 现有长度, minSize)。 */
    private func openMmapSegment(segPath: String, minSize: Int64): Unit {
        let existed = exists(Path(segPath))
        // 映射大小取 max(capacity, 现有文件长度)：既有段可能大于 capacity（例如由非 mmap
        // 后端写入的残留文件），若按 capacity 截断会把有效数据截掉——恢复阶段读到的是残缺记录。
        let existingLen = if (existed) {
            let rf = File(Path(segPath), Read)
            let l = rf.length
            rf.close()
            l
        } else {
            0
        }
        var mapSize = if (existingLen > capacity) { existingLen } else { capacity }
        // 单条记录本身大于 capacity 时，段必须能容纳它，否则换段也无法写入
        if (minSize > mapSize) {
            mapSize = minSize
        }
        this.mmap = Some(MmapFile(segPath, mapSize))
        let f = File(Path(segPath), ReadWrite)
        this.file = Some(f)
        if (existed) {
            // 已存在的段（含崩溃残留）：writeOffset 必须是**有效数据长度**，而不是文件长度——
            // 预分配文件的长度是 capacity，直接当作写偏移会让容量检查立刻判定"已满"，
            // 后续写入全部失败；若残留段由非 mmap 后端写入，长度还可能超过 capacity。
            let (_, validLen) = decodeSegment(segPath, this.mmap, true)
            this.writeOffset = validLen
        } else {
            this.writeOffset = 0
        }
    }

    /** 封口当前段：落盘 → 解除映射 → 截断回收 → 关闭句柄。 */
    private func sealCurrentSegment(): Unit {
        if (let Some(m) <- mmap) {
            m.sync()
            m.close()
            mmap = None
        }
        if (let Some(f) <- file) {
            // 回收未写入的预分配空间：段长度 == 该段实际写入长度
            if (f.length > writeOffset) {
                f.setLength(writeOffset)
            }
            f.close()
            file = None
        }
    }

    /**
     * 换段：封口当前段后新开一段继续追加。
     * 段内始终是固定映射 + 顺序追加，不做运行中 remap（规避 go 自述的段错误窗口）。
     *
     * @param minSize 新段至少需要容纳的字节数（单条记录超过 capacity 时按此扩展）
     */
    private func rotate(minSize: Int64): Unit {
        sealCurrentSegment()
        segIndex += 1
        openMmapSegment(segmentPath(pathStr, segIndex), minSize)
    }

    // ---------------- 打开 ----------------

    /**
     * 打开（或创建）WAL。
     *
     * @param capacity 每段的预分配大小，应不小于该 memtable 可能写入的编码字节数
     *                 （调用方传 arena 大小 = 2 × MemTableSize）。`<= 0` 时退化为 buffered 后端。
     * @param useMmap 是否使用 mmap 写路径（配合 `Config.MmapWAL`）。
     */
    public static func open(path: String, capacity!: Int64 = 0, useMmap!: Bool = true): WAL {
        let p = Path(path)
        let dir = p.parent
        if (dir.toString() != "" && !exists(dir)) {
            Directory.create(dir, recursive: true)
        }

        let mmapMode = useMmap && capacity > 0
        let wal = WAL(path, if (mmapMode) { capacity } else { 0 })

        if (mmapMode) {
            let segs = scanSegments(path)
            if (segs.isEmpty()) {
                wal.segIndex = 0
                wal.openMmapSegment(path, 0)
            } else {
                let last = segs[segs.size - 1]
                wal.segIndex = last
                wal.openMmapSegment(segmentPath(path, last), 0)
                // 末段已写满：直接开新段，避免后续写入立即触发换段判定
                if (wal.writeOffset >= wal.capacity) {
                    wal.rotate(0)
                }
            }
        } else {
            let f = File(p, ReadWrite)
            wal.file = Some(f)
            wal.buf = Some(BufferedOutputStream<File>(f, 65536))
            wal.writeOffset = f.length
        }

        return wal
    }

    /**
     * 只读打开（恢复期读取用，不写入、不截断、不创建）。
     * mmap 模式下映射长度取**实际文件长度**，避免映射超出文件末尾导致访问越界。
     */
    public static func openForRead(path: String, useMmap!: Bool = true): WAL {
        let wal = WAL(path, 0)
        let p = Path(path)
        if (useMmap && exists(p)) {
            let segs = scanSegments(path)
            if (!segs.isEmpty()) {
                wal.segIndex = segs[segs.size - 1]
                let lastPath = segmentPath(path, wal.segIndex)
                let f = File(Path(lastPath), Read)
                let len = f.length
                f.close()
                if (len > 0) {
                    wal.mmap = Some(MmapFile(lastPath, len, readOnly: true))
                    wal.writeOffset = len
                    return wal
                }
            }
            return wal
        }
        let f = File(p, Read)
        wal.file = Some(f)
        wal.writeOffset = f.length
        return wal
    }

    // ---------------- 写 ----------------

    public func write(key: Array<Byte>, valueEncoded: Array<Byte>): Unit {
        let entry = LogEntry(key, valueEncoded)
        let encoded = entry.encode()
        let need = Int64(encoded.size)

        lock.lock()
        try {
            if (mmap.isSome()) {
                // 段写满即换段：单条超过 capacity 时新段按需放大，保证一定能写入
                if (writeOffset + need > capacity) {
                    rotate(need)
                }
                let m = mmap ?? throw Exception("WAL not open for write")
                m.write(encoded, writeOffset)
                writeOffset += need
                return
            }
            let b = buf ?? throw Exception("WAL not open for write")
            b.write(encoded)
            writeOffset += need
        } finally {
            lock.unlock()
        }
    }

    /**
     * 落盘缓冲。mmap 后端写即入映射、无用户态缓冲，此方法为空操作（语义保持，调用方无需分支）。
     */
    public func flush(): Unit {
        if (mmap.isSome()) {
            return
        }
        lock.lock()
        try {
            if (let Some(b) <- buf) {
                b.flush()
            }
        } finally {
            lock.unlock()
        }
    }

    /**
     * 同步到持久介质。mmap 后端 = `msync(MS_SYNC)`（等价 fsync）；buffered 后端 = 刷新缓冲
     * （v1.x 语义：仅交给内核，不做 fsync）。
     */
    public func sync(): Unit {
        lock.lock()
        try {
            if (let Some(m) <- mmap) {
                m.sync()
                return
            }
            if (let Some(b) <- buf) {
                b.flush()
            }
        } finally {
            lock.unlock()
        }
    }

    // ---------------- 读 ----------------

    /**
     * 读取一段：返回 (条目, 有效长度)。
     *
     * 预分配段的尾部是 0 填充：全 0 头的条目 CRC 必然不匹配，因此会在该处停止——
     * 这正是崩溃后"只恢复已写部分"的既有语义。
     */
    private func decodeSegment(segPath: String, mapped: ?MmapFile, isCurrent: Bool): (ArrayList<LogEntry>, Int64) {
        var data: Array<Byte>
        if (isCurrent) {
            if (let Some(m) <- mapped) {
                let total = m.size
                if (total <= 0) {
                    return (ArrayList<LogEntry>(), 0)
                }
                // 段按 capacity 稀疏预分配，映射大小 = 容量：**不能整段读入**，
                // 否则分配量随容量走（容量较大时直接 OOM）。先分块扫描出有效长度再读该段。
                let valid = scanValidLength(m, total)
                if (valid <= 0) {
                    return (ArrayList<LogEntry>(), 0)
                }
                data = m.read(0, valid)
            } else {
                return (ArrayList<LogEntry>(), 0)
            }
        } else {
            // 历史段：临时只读映射，避免长期占用虚拟地址空间
            if (!exists(Path(segPath))) {
                return (ArrayList<LogEntry>(), 0)
            }
            let f = File(Path(segPath), Read)
            let len = f.length
            f.close()
            if (len <= 0) {
                return (ArrayList<LogEntry>(), 0)
            }
            let rm = MmapFile(segPath, len, readOnly: true)
            // 未正常 seal 的段（崩溃残留）文件长度仍是预分配容量，同样只读有效部分
            let valid = scanValidLength(rm, len)
            let d = if (valid > 0) {
                rm.read(0, valid)
            } else {
                Array<Byte>()
            }
            rm.close()
            data = d
        }
        return decodeEntries(data, Int64(data.size))
    }

    public func readAll(): ArrayList<LogEntry> {
        lock.lock()

        try {
            let entries = ArrayList<LogEntry>()

            if (mmap.isSome()) {
                // 逐段按序拼接：段内顺序追加，段间保持写入先后
                for (i in 0..(segIndex + 1)) {
                    let segPath = segmentPath(pathStr, i)
                    let isCurrent = (i == segIndex)
                    let (parsed, validLen) = decodeSegment(segPath, mmap, isCurrent)
                    entries.add(all: parsed)
                    if (isCurrent) {
                        // 末段的 writeOffset 收敛为有效长度，供后续追加使用
                        writeOffset = validLen
                    }
                }
                return entries
            }

            if (let Some(b) <- buf) {
                b.flush()
            }
            let f = file ?? throw Exception("WAL file not open")
            let fileLength = f.length
            if (fileLength == 0) {
                return entries
            }
            f.seek(SeekPosition.Begin(0))
            let data = Array<Byte>(fileLength, repeat: 0)
            let bytesRead = f.read(data)
            if (bytesRead != fileLength) {
                throw Exception("Failed to read complete WAL file: got ${bytesRead}, expected ${fileLength}")
            }
            let (parsed, _) = decodeEntries(data, fileLength)
            return parsed
        } finally {
            lock.unlock()
        }
    }

    /**
     * 按顺序解码条目，遇到第一个解码/校验失败即停止（等价"尾部截断"）。
     * 返回 (条目列表, 成功解析的字节数)。
     *
     * `entrySize <= 0` 的防御用于杜绝解码器返回零长度时可能造成的死循环。
     */
    /** 从字节数组读小端 u32。 */
    private func u32At(data: Array<Byte>, offset: Int64): UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    /**
     * 扫描映射段的有效数据长度。
     *
     * 段按 capacity 稀疏预分配，后部是 0 填充：全 0 头的条目 CRC 必然不匹配，扫描在该处
     * 停止——与 `decodeEntries` 的「尾部截断」语义一致。**必须按块读取**：内存占用为
     * O(块大小 + 单条记录)，不随段容量增长；整段读入会在容量较大时直接 OOM。
     */
    private func scanValidLength(m: MmapFile, total: Int64): Int64 {
        let chunkSize: Int64 = 1 << 20
        var valid: Int64 = 0
        var blockStart: Int64 = 0
        while (blockStart < total) {
            let remain = total - blockStart
            let n = if (remain > chunkSize) { chunkSize } else { remain }
            let block = m.read(blockStart, n)
            var p: Int64 = 0
            var stop = false
            while (true) {
                let avail = Int64(block.size) - p
                if (avail < 13) {
                    break
                }
                let keyLen = u32At(block, p)
                let valLen = u32At(block, p + 4)
                let entrySize = 13 + Int64(keyLen) + Int64(valLen)
                if (entrySize <= 13) {
                    stop = true
                    break
                }
                if (avail < entrySize) {
                    break
                }
                let slice = block[p..(p + entrySize)]
                try {
                    let (_, decoded) = LogEntry.decode(slice, 0)
                    if (decoded != entrySize) {
                        stop = true
                        break
                    }
                } catch (e: Exception) {
                    stop = true
                    break
                }
                p += entrySize
            }
            if (p > 0) {
                valid += p
                blockStart += p
            }
            if (stop) {
                break
            }
            if (p > 0) {
                continue
            }
            // 块首条不完整（跨块或单条大于块）：按头部长度单条读取，保证仍能前进
            if (Int64(block.size) < 13) {
                break
            }
            let keyLen = u32At(block, 0)
            let valLen = u32At(block, 4)
            let entrySize = 13 + Int64(keyLen) + Int64(valLen)
            if (entrySize <= 13 || blockStart + entrySize > total) {
                break
            }
            let one = m.read(blockStart, entrySize)
            try {
                let (_, decoded) = LogEntry.decode(one, 0)
                if (decoded != entrySize) {
                    break
                }
            } catch (e: Exception) {
                break
            }
            valid += entrySize
            blockStart += entrySize
        }
        return valid
    }

    private func decodeEntries(data: Array<Byte>, length: Int64): (ArrayList<LogEntry>, Int64) {
        let entries = ArrayList<LogEntry>()
        var offset: Int64 = 0
        while (offset + 9 <= length) {
            try {
                let (entry, entrySize) = LogEntry.decode(data, offset)
                if (entrySize <= 0) {
                    println("[badger] WAL decode returned non-positive size at offset ${offset}/${length}, truncating rest of WAL")
                    break
                }
                entries.add(entry)
                offset += entrySize
            } catch (e: Exception) {
                // 解码失败按 WAL 尾部截断处理：不再解析剩余字节（语义不变），
                // 但必须留痕——否则被丢掉的这段写记录在恢复后毫无痕迹。
                println("[badger] WAL decode failed at offset ${offset}/${length}, truncating rest of WAL: " + e.toString())
                break
            }
        }
        return (entries, offset)
    }

    // ---------------- 恢复 ----------------

    protected func replay(mt: MemTable): Unit {
        // 恢复期标记：期间 mt.put 不回写 WAL（数据本就来自 WAL；重写还会撞上
        // 段容量上限——残留段可能大于本 memtable 的 capacity）
        mt.beginReplay()
        try {
            replayEntries(mt)
        } finally {
            mt.endReplay()
        }
    }

    private func replayEntries(mt: MemTable): Unit {
        let entries = readAll()

        var pendingTxnEntries = ArrayList<(Array<Byte>, ValueStruct)>()
        var lastTxnTs: UInt64 = 0

        for (entry in entries) {
            let vs = ValueStruct.decode(entry.value)

            if (vs.isFinTxn()) {
                let txnTs = parseTs(entry.key)
                if (txnTs == lastTxnTs) {
                    // 整事务原子恢复（评审 P2-3）：任一条目写失败（超限/arena 满）
                    // → 丢弃整个事务，不再恢复其余条目。此前逐条跳过会让失败事务的
                    // 部分数据"复活"，与"失败必报"语义矛盾。启动不崩仍由外层容错保证。
                    var txnFailed = false
                    for ((key, value) in pendingTxnEntries) {
                        if (txnFailed) {
                            continue
                        }
                        let cleanVs = value.clearTxnMarks()
                        try {
                            mt.put(key, cleanVs)
                        } catch (e: Exception) {
                            // 整事务丢弃是刻意的原子性选择（失败事务不许部分复活），
                            // 但"失败必报"：不打印则这次数据丢失在恢复期完全不可见。
                            txnFailed = true
                            println("[badger] WAL replay: txn put failed, dropping whole txn (ts=${txnTs}): " + e.toString())
                        }
                    }
                }
                pendingTxnEntries.clear()
                lastTxnTs = 0
            } else if (vs.isTxnEntry()) {
                let txnTs = parseTs(entry.key)
                if (lastTxnTs == 0) {
                    lastTxnTs = txnTs
                    pendingTxnEntries.add((entry.key, vs))
                } else if (txnTs == lastTxnTs) {
                    pendingTxnEntries.add((entry.key, vs))
                } else {
                    pendingTxnEntries.clear()
                    lastTxnTs = txnTs
                    pendingTxnEntries.add((entry.key, vs))
                }
            } else {
                if (lastTxnTs != 0) {
                    pendingTxnEntries.clear()
                    lastTxnTs = 0
                }
                try {
                    mt.put(entry.key, vs)
                } catch (e: Exception) {
                    // 单条坏数据（超限/容器满）跳过，其余继续恢复
                    // （跳过语义不变，但必须留痕：否则这条数据静默丢失，事后无法归因）
                    println("[badger] WAL replay: skip bad entry (keyLen=${entry.key.size}): " + e.toString())
                }
            }
        }
    }

    // ---------------- 关闭 / 删除 ----------------

    /**
     * 关闭：同步落盘 → 解除映射 → 截断回收（把每段预分配的稀疏空间缩回实际写入长度）。
     * 截断必须在 munmap 之后，否则已解除的映射区再被访问会 SIGBUS。
     */
    public func close(): Unit {
        lock.lock()

        try {
            if (mmap.isSome()) {
                // 历史段在换段时已封口并截断，这里只需收尾当前段
                sealCurrentSegment()
                return
            }
            if (let Some(b) <- buf) {
                b.flush()
            }
            if (let Some(f) <- file) {
                f.close()
                file = None
            }
            buf = None
        } finally {
            lock.unlock()
        }
    }

    public func delete(): Unit {
        lock.lock()

        try {
            if (mmap.isSome()) {
                if (let Some(m) <- mmap) {
                    m.close()
                }
                mmap = None
                if (let Some(f) <- file) {
                    f.close()
                    file = None
                }
            } else {
                if (let Some(b) <- buf) {
                    b.flush()
                }
                if (let Some(f) <- file) {
                    f.close()
                    file = None
                }
                buf = None
            }

            // 删除所有段
            var i: Int64 = 0
            while (exists(Path(segmentPath(pathStr, i)))) {
                remove(Path(segmentPath(pathStr, i)))
                i += 1
            }
        } finally {
            lock.unlock()
        }
    }

    public func path(): String {
        return pathStr
    }
}
