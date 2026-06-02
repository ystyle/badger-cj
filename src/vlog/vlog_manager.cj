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
        
        let newFile = VLogFile.create(dir.join("0.vlog"), 0)
        this.currentFile = newFile
        this.files[0] = newFile
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
    
    public func write(entry: LogEntry): UInt32 {
        let encoded = entry.encode()
        
        if (!inMemory) {
            if (let Some(f) <- file) {
                f.seek(SeekPosition.End(0))
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