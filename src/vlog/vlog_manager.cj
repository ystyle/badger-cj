package badgercj.vlog

import std.collection.*
import std.fs.*
import std.io.*
import std.sync.*
import std.convert.*
import badgercj.table.*
import mmapcj.*

/** 段剩余空间放不下当前记录：由 VLogManager 捕获后换段重试（不做运行中 remap）。 */
public class VLogSegmentFull <: Exception {
    public let needed: UInt32
    public init(needed: UInt32) {
        super("VLog segment full: need ${needed} bytes")
        this.needed = needed
    }
}

/**
 * VLogManager - Value Log 管理器
 * 
 * 管理多个 VLog 文件，支持大值分离存储。
 *
 * 段模型：`<fid>.vlog`，每段按 `maxFileSize` **稀疏预分配**并建立段内固定映射
 * （`useMmap` 打开时；关闭则回退无缓冲 `File.write`，即 v1.x 路径）。
 * 段内顺序追加、写满换段，段内不做运行中 remap。
 */
protected class VLogManager {
    private let dir: Path
    private let opt: VLogOptions
    private let lock: Mutex
    private let inMemory: Bool
    
    private var files: HashMap<UInt32, VLogFile>
    private var maxFid: UInt32
    private var currentFile: VLogFile
    private var offset: UInt32
    
    private var db: ?VLogGCDB
    private var discardChecker: ?DiscardChecker
    private let discardStats: DiscardStats
    
    public init() {
        this.dir = Path("")
        this.opt = VLogOptions()
        this.lock = Mutex()
        this.inMemory = true
        this.files = HashMap<UInt32, VLogFile>()
        this.maxFid = 0
        this.offset = 0
        this.db = None
        this.discardChecker = None
        this.discardStats = DiscardStats()
        
        // InMemory 模式下不创建实际文件
        this.currentFile = VLogFile.memory(0)
        this.files[0] = this.currentFile
    }
    
    public init(dir: Path, opt!: VLogOptions = VLogOptions()) {
        this.dir = dir
        this.opt = opt
        this.lock = Mutex()
        this.inMemory = false
        this.files = HashMap<UInt32, VLogFile>()
        this.maxFid = 0
        this.offset = 0
        this.db = None
        this.discardChecker = None
        this.discardStats = DiscardStats(dir)
        
        // 恢复已有段：VLog 是长期文件，重开时必须重建段表与写偏移——
        // 否则新写入的 ValuePointer.offset 会从 0 开始（读到别的旧值 = 静默数据损坏），
        // 且换段会回到已存在的 fid 把旧段覆盖掉。
        let segments = VLogManager.listSegments(dir)
        if (segments.isEmpty()) {
            let newFile = VLogFile.create(dir.join("0.vlog"), 0, opt.maxFileSize, opt.useMmap)
            this.currentFile = newFile
            this.files[0] = newFile
        } else {
            var last: ?VLogFile = None
            for ((fid, path) in segments) {
                let f = VLogFile.open(path, fid, opt.maxFileSize, opt.useMmap)
                this.files[fid] = f
                this.maxFid = fid
                last = Some(f)
            }
            this.currentFile = last ?? throw Exception("VLog restore: no segment")
            // 写偏移 = 末段的有效数据长度（已由 VLogFile 扫描恢复）
            this.offset = this.currentFile.size()
        }
    }

    /**
     * 列出目录下已有的段（fid 升序）。
     * 文件名形如 `<fid>.vlog`，非该形式的文件忽略。
     */
    private static func listSegments(dir: Path): ArrayList<(UInt32, Path)> {
        let result = ArrayList<(UInt32, Path)>()
        if (!exists(dir)) {
            return result
        }
        let entries = Directory.readFrom(dir)
        let found = HashMap<UInt32, Path>()
        for (e in entries) {
            let name = e.name
            if (!name.endsWith(".vlog")) {
                continue
            }
            let idStr = name[0..(name.size - 5)]
            match (Int64.tryParse(idStr)) {
                case Some(v) =>
                    if (v >= 0 && v <= Int64(UInt32.Max)) {
                        found[UInt32(v)] = dir.join(name)
                    }
                case None => ()
            }
        }
        let fids = ArrayList<UInt32>()
        for ((fid, _) in found) {
            fids.add(fid)
        }
        fids.sort()
        for (fid in fids) {
            match (found.get(fid)) {
                case Some(p) => result.add((fid, p))
                case None => ()
            }
        }
        return result
    }
    
    public func setDB(db: VLogGCDB, discardChecker!: DiscardChecker = { _, _ => false }): Unit {
        this.db = Some(db)
        this.discardChecker = Some(discardChecker)
    }
    
    public func write(entry: LogEntry): ValuePointer {
        synchronized (lock) {
            if (UInt64(currentFile.size()) >= UInt64(opt.maxFileSize)) {
                rotateSegment(0)
            }
            try {
                let currentOffset = offset
                let written = currentFile.write(entry)
                offset += written
                return ValuePointer(currentFile.fid, written, currentOffset)
            } catch (e: VLogSegmentFull) {
                // 本段剩余空间放不下这条记录（段尾碎片）：换段后用能容纳它的段大小重试。
                // 段内不做运行中 remap，与 WAL 的容量兜底保持同一策略。
                rotateSegment(e.needed)
                let currentOffset = offset
                let written = currentFile.write(entry)
                offset += written
                return ValuePointer(currentFile.fid, written, currentOffset)
            }
        }
    }

    /**
     * 换段：关闭旧段（截断回收）后开新段。
     * @param minSize 新段至少要容纳的字节数——单条记录超过 maxFileSize 时按它放大，
     *                否则换段也写不进去。
     */
    private func rotateSegment(minSize: UInt32): Unit {
        maxFid += 1
        let newPath = dir.join("${maxFid}.vlog")
        var segSize = opt.maxFileSize
        if (minSize > segSize) {
            segSize = minSize
        }
        let newFile = VLogFile.create(newPath, maxFid, segSize, opt.useMmap)
        files[maxFid] = newFile
        currentFile = newFile
        offset = 0
    }
    
    public func read(vp: ValuePointer): LogEntry {
        synchronized (lock) {
            if (!files.contains(vp.fid)) {
                throw Exception("VLog file not found: ${vp.fid}")
            }
            
            let file = files[vp.fid]
            return file.read(vp.offset, vp.len)
        }
    }
    
    public func close(): Unit {
        synchronized (lock) {
            for ((_, file) in files) {
                file.close()
            }
        }
    }
    
    public func sync(): Unit {
        synchronized (lock) {
            for ((_, file) in files) {
                file.sync()
            }
        }
    }
    
    public func size(): UInt64 {
        var total: UInt64 = 0
        synchronized (lock) {
            for ((_, file) in files) {
                total += UInt64(file.size())
            }
        }
        return total
    }
    
    public func getDiscardRatio(fid: UInt32): Float64 {
        synchronized (lock) {
            if (!files.contains(fid)) {
                return 0.0
            }
            
            let file = files[fid]
            let totalSize = Int64(file.size())
            
            if (totalSize == 0) {
                return 0.0
            }
            
            let discard = discardStats.get(fid)
            return Float64(discard) / Float64(totalSize)
        }
    }
    
    public func iterate(fid: UInt32, callback: (LogEntry, UInt32) -> Bool): Unit {
        synchronized (lock) {
            if (!files.contains(fid)) {
                return
            }
            
            let file = files[fid]
            file.iterate(callback)
        }
    }
    
    public func pickLog(discardRatio: Float64): ?UInt32 {
        synchronized (lock) {
            var targetFid: ?UInt32 = None
            var maxRatio: Float64 = 0.0
            
            for ((fid, _) in files) {
                if (fid == currentFile.fid) {
                    continue
                }
                
                let ratio = getDiscardRatio(fid)
                if (ratio >= discardRatio && ratio > maxRatio) {
                    maxRatio = ratio
                    targetFid = Some(fid)
                }
            }
            
            return targetFid
        }
    }
    
    public func rewrite(fid: UInt32): Bool {
        match ((db, discardChecker)) {
            case (Some(gcDb), Some(checker)) =>
                let rewriter = GCFileRewriter(gcDb, fid, shouldDiscard: checker)
                synchronized (lock) {
                    if (!files.contains(fid)) {
                        return false
                    }
                    let file = files[fid]
                    file.iterate({ entry, offset =>
                        rewriter.process(entry, offset)
                    })
                }
                rewriter.flush()
                
                synchronized (lock) {
                    if (files.contains(fid)) {
                        files.remove(fid)
                        discardStats.clear(fid)
                    }
                }
                return true
            case _ =>
                return false
        }
    }
    
    private func batchRewrite(gcDb: VLogGCDB, entries: ArrayList<(Array<Byte>, LogEntry)>): Unit {
        for ((key, entry) in entries) {
            gcDb.setRaw(key, entry.value, entry.meta, entry.version, entry.expiresAt)
        }
    }
    
    public func runGC(discardRatio: Float64): Bool {
        let fidOpt = pickLog(discardRatio)
        if (let Some(fid) <- fidOpt) {
            return rewrite(fid)
        }
        return false
    }
    
    public func addDiscard(fid: UInt32, size: Int64): Unit {
        discardStats.update(fid, size)
    }
    
    public func getCurrentFid(): UInt32 {
        synchronized (lock) {
            currentFile.fid
        }
    }
    
    public func getFileCount(): Int64 {
        synchronized (lock) {
            files.size
        }
    }
}

/**
 * VLogFile - 单个 VLog 文件
 *
 * 支持两种模式：
 * - inMemory: 使用 ArrayList<Byte> 内存缓冲
 * - 磁盘: `useMmap` 打开时按 `maxFileSize` 稀疏预分配 + 固定映射（写走 memcpy）；
 *   否则回退无缓冲 `File.write`（v1.x 路径）
 *
 * 逻辑大小 `size()` 恒为**已写入的有效字节数**，与物理文件长度解耦——预分配后
 * 文件长度是 `maxFileSize`，直接拿它当写偏移会写出空洞。
 */
public class VLogFile {
    public let fid: UInt32
    private let path: Path
    private var file: ?File
    private var mmap: ?MmapFile
    private var writeOffset: UInt32
    private let maxFileSize: UInt32
    private let useMmap: Bool
    private let buf: ArrayList<Byte>
    private let inMemory: Bool
    
    private init(fid: UInt32, path: Path, file: ?File, mmap: ?MmapFile, writeOffset: UInt32,
        maxFileSize: UInt32, useMmap: Bool, buf: ArrayList<Byte>, inMemory: Bool) {
        this.fid = fid
        this.path = path
        this.file = file
        this.mmap = mmap
        this.writeOffset = writeOffset
        this.maxFileSize = maxFileSize
        this.useMmap = useMmap
        this.buf = buf
        this.inMemory = inMemory
    }
    
    public static func memory(fid: UInt32): VLogFile {
        let noFile: ?File = None
        let noMmap: ?MmapFile = None
        VLogFile(fid, Path(""), noFile, noMmap, 0, 0, false, ArrayList<Byte>(), true)
    }
    
    /** 新建（或打开后由调用方恢复）一个段；`maxFileSize == 0` 表示内存模式不能走这里。 */
    public static func create(path: Path, fid: UInt32, maxFileSize: UInt32, useMmap: Bool): VLogFile {
        let parent = path.parent
        if (parent.toString() != "" && !exists(parent)) {
            Directory.create(parent, recursive: true)
        }
        if (useMmap && maxFileSize > 0) {
            let m = MmapFile(path.toString(), Int64(maxFileSize))
            let f = File(path, ReadWrite)
            return VLogFile(fid, path, Some(f), Some(m), 0, maxFileSize, true, ArrayList<Byte>(), false)
        }
        let f = File(path, ReadWrite)
        f.seek(SeekPosition.End(0))
        return VLogFile(fid, path, Some(f), Option<MmapFile>.None, 0, maxFileSize, false, ArrayList<Byte>(), false)
    }

    /**
     * 打开已有段并恢复其有效写入长度。
     * 有效长度 = 顺序解析到最后一个完整条目为止的字节数：段是 append-only 的，
     * 中途若有不完整/损坏的尾部（崩溃残留）即在此截断，与 WAL 的恢复语义一致。
     */
    public static func open(path: Path, fid: UInt32, maxFileSize: UInt32, useMmap: Bool): VLogFile {
        if (!exists(path)) {
            return VLogFile.create(path, fid, maxFileSize, useMmap)
        }
        let f = File(path, ReadWrite)
        let physicalLen = f.length
        var valid: UInt32 = 0
        if (physicalLen > 0) {
            valid = VLogFile.scanValidLength(f, physicalLen)
        }
        // 映射大小取 max(maxFileSize, 现有长度)：已有段可能比 maxFileSize 长（配置变小或旧版本写入）
        var mapSize = Int64(maxFileSize)
        if (physicalLen > mapSize) {
            mapSize = physicalLen
        }
        if (useMmap && mapSize > 0) {
            let m = MmapFile(path.toString(), mapSize)
            return VLogFile(fid, path, Some(f), Some(m), valid, maxFileSize, true, ArrayList<Byte>(), false)
        }
        return VLogFile(fid, path, Some(f), Option<MmapFile>.None, valid, maxFileSize, false, ArrayList<Byte>(), false)
    }

    /**
     * 流式扫描，返回最后一个完整条目结束处的偏移；遇到解码失败即停（尾部截断语义）。
     *
     * **不能把整段读进内存**：段按 maxFileSize 稀疏预分配（默认 1GB），整体读入会 OOM。
     * 逐条按需读取即可——段是 append-only 的，未写入区域是 0 填充，其 CRC 必然不匹配，
     * 因此通常只读到"已写数据的末尾 + 一条"就停止。
     */
    private static func scanValidLength(f: File, physicalLen: Int64): UInt32 {
        var offset: Int64 = 0
        while (offset + 9 <= physicalLen) {
            f.seek(SeekPosition.Begin(offset))
            let header = Array<Byte>(9, repeat: 0)
            if (f.read(header) != 9) {
                break
            }
            let keyLen = UInt32(header[0]) | (UInt32(header[1]) << 8) |
                (UInt32(header[2]) << 16) | (UInt32(header[3]) << 24)
            let valLen = UInt32(header[4]) | (UInt32(header[5]) << 8) |
                (UInt32(header[6]) << 16) | (UInt32(header[7]) << 24)
            // 条目布局：keyLen(4) + valueLen(4) + key + value + meta(1) + crc(4)
            // → 固定开销 13 字节。（9 只是"最小可解码头部"的保守下界，不是条目开销。）
            let entrySize = 13 + Int64(keyLen) + Int64(valLen)
            if (entrySize <= 13 || offset + entrySize > physicalLen) {
                break
            }
            f.seek(SeekPosition.Begin(offset))
            let data = Array<Byte>(entrySize, repeat: 0)
            if (f.read(data) != entrySize) {
                break
            }
            try {
                let (_, decodedSize) = LogEntry.decode(data, 0)
                if (decodedSize != entrySize) {
                    break
                }
                offset += entrySize
            } catch (e: Exception) {
                break
            }
        }
        return UInt32(offset)
    }
    
    public func write(entry: LogEntry): UInt32 {
        let encoded = entry.encode()
        
        if (!inMemory) {
            if (let Some(m) <- mmap) {
                let need = writeOffset + UInt32(encoded.size)
                if (UInt64(need) > UInt64(maxFileSize)) {
                    throw VLogSegmentFull(need)
                }
                m.write(encoded, Int64(writeOffset))
                writeOffset = need
                return UInt32(encoded.size)
            }
            if (let Some(f) <- file) {
                f.write(encoded)
                writeOffset += UInt32(encoded.size)
            }
            return UInt32(encoded.size)
        }
        
        for (b in encoded) {
            buf.add(b)
        }
        return UInt32(encoded.size)
    }
    
    public func read(offset: UInt32, len: UInt32): LogEntry {
        if (!inMemory) {
            if (let Some(m) <- mmap) {
                let data = m.read(Int64(offset), Int64(len))
                let (entry, _) = LogEntry.decode(data, 0)
                return entry
            }
            if (let Some(f) <- file) {
                f.seek(SeekPosition.Begin(Int64(offset)))
                let data = Array<Byte>(Int64(len), repeat: 0)
                let bytesRead = f.read(data)
                if (bytesRead != Int64(len)) {
                    throw Exception("VLogFile.read: expected ${len} bytes, got ${bytesRead}")
                }
                let (entry, _) = LogEntry.decode(data, 0)
                return entry
            }
        }
        
        let start = Int64(offset)
        let end = start + Int64(len)
        let data = buf.toArray()[start..end]
        let (entry, _) = LogEntry.decode(data, 0)
        return entry
    }
    
    /** 逻辑大小：已写入的有效字节数（不是物理文件长度——预分配后后者是 maxFileSize）。 */
    public func size(): UInt32 {
        if (!inMemory) {
            return writeOffset
        }
        return UInt32(buf.size)
    }
    
    public func close(): Unit {
        if (!inMemory) {
            if (let Some(m) <- mmap) {
                m.sync()
                m.close()
                mmap = None
            }
            if (let Some(f) <- file) {
                // 回收未写入的预分配空间：物理长度缩回实际有效数据长度
                if (UInt64(f.length) > UInt64(writeOffset)) {
                    f.setLength(Int64(writeOffset))
                }
                f.close()
                file = None
            }
        }
    }
    
    public func sync(): Unit {
        if (!inMemory) {
            if (let Some(m) <- mmap) {
                m.sync()
                return
            }
            if (let Some(f) <- file) {
                f.flush()
            }
        }
    }
    
    public func iterate(callback: (LogEntry, UInt32) -> Bool): Unit {
        let data: Array<Byte>
        let totalSize: Int64
        
        if (!inMemory) {
            if (let Some(m) <- mmap) {
                // 只遍历有效区间：预分配尾部是 0 填充，解不出条目
                totalSize = Int64(writeOffset)
                if (totalSize == 0) {
                    return
                }
                data = m.read(0, totalSize)
            } else if (let Some(f) <- file) {
                f.seek(SeekPosition.Begin(0))
                let fileLen = Int64(writeOffset)
                if (fileLen == 0) {
                    return
                }
                data = Array<Byte>(fileLen, repeat: 0)
                let bytesRead = f.read(data)
                if (bytesRead != fileLen) {
                    throw Exception("VLogFile.iterate: read incomplete")
                }
                totalSize = fileLen
            } else {
                return
            }
        } else {
            data = buf.toArray()
            totalSize = Int64(data.size)
        }
        
        var offset: UInt32 = 0
        while (Int64(offset) < totalSize) {
            let (entry, bytesRead) = LogEntry.decode(data, Int64(offset))
            if (!callback(entry, offset)) {
                break
            }
            offset += UInt32(bytesRead)
        }
    }
}

/**
 * VLogOptions - VLog 配置
 */
public struct VLogOptions {
    public var maxFileSize: UInt32 = 1024 * 1024 * 1024
    public var valueThreshold: Int64 = 1024
    /** 段是否走 mmap（稀疏预分配 + 段内固定映射）；关闭则回退无缓冲 File.write */
    public var useMmap: Bool = true
    
    public init() {}
}
