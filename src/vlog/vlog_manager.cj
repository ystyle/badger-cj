package badgercj.vlog

import std.collection.*
import std.fs.*
import std.io.*
import std.sync.*
import badgercj.table.*

/**
 * VLogManager - Value Log 管理器
 * 
 * 管理多个 VLog 文件，支持大值分离存储
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
        
        // VLog 段是长期文件：重开时必须重建段表与写偏移。
        // 若无条件 create("0.vlog")，新写入的 ValuePointer.offset 会从 0 开始——
        // 读路径（Badger.get）只按指针取记录、不校验 key，于是静默读到段首的其它值；
        // maxFid 恒 0 还会在换段时复用已存在的 fid，把旧段直接覆盖掉。
        let segments = VLogManager.listSegments(dir)
        if (segments.isEmpty()) {
            let newFile = VLogFile.create(dir.join("0.vlog"), 0)
            this.currentFile = newFile
            this.files[0] = newFile
        } else {
            var last: ?VLogFile = None
            var lastValidLength: UInt32 = 0
            for ((fid, path) in segments) {
                // open 顺序扫描到最后一个完整条目，并截断崩溃残留的尾部
                let (file, validLength) = VLogFile.open(path, fid)
                this.files[fid] = file
                this.maxFid = fid
                last = Some(file)
                lastValidLength = validLength
            }
            this.currentFile = last ?? throw Exception("VLog restore: no segment found in ${dir}")
            this.offset = lastValidLength
        }
    }
    
    /**
     * 列出目录下已有的段，按 fid 升序。
     *
     * 段名约定为 `<fid>.vlog`，fid 是无前导零的十进制 UInt32（写入侧即如此命名）。
     * 其余文件（如 notes.txt、abc.vlog、.vlog、007.vlog）与同名目录一律忽略——
     * 数据目录里同时混有 MANIFEST / WAL / SST / 用户文件。
     */
    private static func listSegments(dir: Path): ArrayList<(UInt32, Path)> {
        let result = ArrayList<(UInt32, Path)>()
        if (!exists(dir)) {
            return result
        }
        let found = HashMap<UInt32, Path>()
        for (entry in Directory.readFrom(dir)) {
            if (entry.isDirectory()) {
                continue
            }
            match (VLogManager.parseFid(entry.name)) {
                case Some(fid) => found[fid] = dir.join(entry.name)
                case None => ()
            }
        }
        let fids = ArrayList<UInt32>()
        for ((fid, _) in found) {
            fids.add(fid)
        }
        fids.sort()
        for (fid in fids) {
            if (let Some(path) <- found.get(fid)) {
                result.add((fid, path))
            }
        }
        return result
    }
    
    /** 解析段名 `<fid>.vlog`；不符合命名约定返回 None。 */
    private static func parseFid(name: String): ?UInt32 {
        if (!name.endsWith(".vlog")) {
            return None
        }
        let digits = name[0..(name.size - 5)]
        if (digits.size == 0) {
            return None
        }
        let bytes = digits.toArray()
        // 写入侧不使用前导零；拒绝 "007.vlog" 这类别名，避免同一 fid 出现两个文件
        if (bytes.size > 1 && UInt64(bytes[0]) == 0x30) {
            return None
        }
        var value: UInt64 = 0
        for (b in bytes) {
            let d = UInt64(b)
            if (d < 0x30 || d > 0x39) {
                return None
            }
            value = value * 10 + (d - 0x30)
            if (value > UInt64(UInt32.Max)) {
                return None
            }
        }
        return Some(UInt32(value))
    }
    
    public func setDB(db: VLogGCDB, discardChecker!: DiscardChecker = { _, _ => false }): Unit {
        this.db = Some(db)
        this.discardChecker = Some(discardChecker)
    }
    
    public func write(entry: LogEntry): ValuePointer {
        synchronized (lock) {
            if (UInt64(currentFile.size()) >= UInt64(opt.maxFileSize)) {
                maxFid += 1
                let newPath = dir.join("${maxFid}.vlog")
                let newFile = VLogFile.create(newPath, maxFid)
                files[maxFid] = newFile
                currentFile = newFile
                offset = 0
            }
            
            let currentOffset = offset
            let written = currentFile.write(entry)
            offset += written
            
            return ValuePointer(currentFile.fid, written, currentOffset)
        }
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
 * - file: 写入磁盘文件（持久化模式）
 */
public class VLogFile {
    public let fid: UInt32
    private let path: Path
    private var file: ?File
    private let buf: ArrayList<Byte>
    private let inMemory: Bool
    
    /** 条目固定开销：keyLen(4) + valueLen(4) + meta(1) + crc(4)。 */
    private static let ENTRY_FIXED_OVERHEAD: Int64 = 13
    
    private init(fid: UInt32, path: Path, file: ?File, buf: ArrayList<Byte>, inMemory: Bool) {
        this.fid = fid
        this.path = path
        this.file = file
        this.buf = buf
        this.inMemory = inMemory
    }
    
    public static func memory(fid: UInt32): VLogFile {
        let noFile: ?File = None
        VLogFile(fid, Path(""), noFile, ArrayList<Byte>(), true)
    }
    
    public static func create(path: Path, fid: UInt32): VLogFile {
        let parent = path.parent
        if (parent.toString() != "" && !exists(parent)) {
            Directory.create(parent, recursive: true)
        }
        let f = File(path, ReadWrite)
        f.seek(SeekPosition.End(0))
        VLogFile(fid, path, Some(f), ArrayList<Byte>(), false)
    }
    
    /**
     * 打开已有段并恢复其有效写入长度。
     *
     * 段是 append-only 的：顺序解析到最后一个完整条目（CRC 校验通过）为止，
     * 崩溃残留的残缺尾部在此截断——与 WAL 的恢复语义一致。
     * 返回的文件已 seek 到末尾、可直接续写；第二个返回值是有效长度（写偏移基线）。
     */
    public static func open(path: Path, fid: UInt32): (VLogFile, UInt32) {
        if (!exists(path)) {
            let created = VLogFile.create(path, fid)
            return (created, 0)
        }
        let f = File(path, ReadWrite)
        let physicalLength = f.length
        var validLength: UInt32 = 0
        if (physicalLength > 0) {
            validLength = VLogFile.scanValidLength(f, physicalLength)
            if (physicalLength > Int64(validLength)) {
                // 只回收崩溃残留的尾部；有效数据一个字节都不动
                f.setLength(Int64(validLength))
                println("[badger] VLog segment ${path} truncated corrupt tail: ${physicalLength} -> ${validLength}")
            }
        }
        f.seek(SeekPosition.End(0))
        return (VLogFile(fid, path, Some(f), ArrayList<Byte>(), false), validLength)
    }
    
    /**
     * 顺序扫描段内条目，返回最后一个完整条目结束处的偏移；遇到不完整 / CRC 失败 /
     * 长度越界即停。
     *
     * 不把整段读进内存：逐条按需读取，缓冲最多一条记录那么大。
     * 条目布局 keyLen(4) + valueLen(4) + key + value + meta(1) + crc(4)，固定开销 13 字节。
     */
    private static func scanValidLength(f: File, physicalLength: Int64): UInt32 {
        var offset: Int64 = 0
        while (offset + 9 <= physicalLength) {
            f.seek(SeekPosition.Begin(offset))
            let header = Array<Byte>(9, repeat: 0)
            if (f.read(header) != 9) {
                break
            }
            let keyLength = UInt32(header[0]) | (UInt32(header[1]) << 8) |
                (UInt32(header[2]) << 16) | (UInt32(header[3]) << 24)
            let valueLength = UInt32(header[4]) | (UInt32(header[5]) << 8) |
                (UInt32(header[6]) << 16) | (UInt32(header[7]) << 24)
            let entrySize = ENTRY_FIXED_OVERHEAD + Int64(keyLength) + Int64(valueLength)
            // 长度越界：崩溃残留的垃圾头部可能声称几 GB，必须先校验再分配缓冲
            if (entrySize > physicalLength - offset) {
                break
            }
            f.seek(SeekPosition.Begin(offset))
            let data = Array<Byte>(entrySize, repeat: 0)
            if (f.read(data) != entrySize) {
                break
            }
            var valid = false
            try {
                let (_, decodedSize) = LogEntry.decode(data, 0)
                valid = decodedSize == entrySize
            } catch (e: Exception) {
                valid = false
            }
            if (!valid) {
                break
            }
            offset += entrySize
        }
        return UInt32(offset)
    }
    
    public func write(entry: LogEntry): UInt32 {
        let encoded = entry.encode()
        
        if (!inMemory) {
            if (let Some(f) <- file) {
                f.write(encoded)
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
    
    public func size(): UInt32 {
        if (!inMemory) {
            if (let Some(f) <- file) {
                return UInt32(f.length)
            }
        }
        return UInt32(buf.size)
    }
    
    public func close(): Unit {
        if (!inMemory) {
            if (let Some(f) <- file) {
                f.close()
                file = None
            }
        }
    }
    
    public func sync(): Unit {
        if (!inMemory) {
            if (let Some(f) <- file) {
                f.flush()
            }
        }
    }
    
    public func iterate(callback: (LogEntry, UInt32) -> Bool): Unit {
        let data: Array<Byte>
        let totalSize: Int64
        
        if (!inMemory) {
            if (let Some(f) <- file) {
                f.seek(SeekPosition.Begin(0))
                let fileLen = f.length
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
    
    public init() {}
}