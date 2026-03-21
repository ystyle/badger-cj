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
    
    private var files: HashMap<UInt32, VLogFile>
    private var maxFid: UInt32
    private var currentFile: VLogFile
    private var offset: UInt32
    
    private var db: ?VLogGCDB
    private var discardChecker: ?DiscardChecker
    private let discardStats: DiscardStats
    
    public init(dir: Path, opt!: VLogOptions = VLogOptions()) {
        this.dir = dir
        this.opt = opt
        this.lock = Mutex()
        this.files = HashMap<UInt32, VLogFile>()
        this.maxFid = 0
        this.offset = 0
        this.db = None
        this.discardChecker = None
        this.discardStats = DiscardStats(dir)
        
        let newFile = VLogFile.create(Path("./0.vlog"), 0)
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
 */
public class VLogFile {
    public let fid: UInt32
    private let path: Path
    private let buf: ArrayList<Byte>
    
    private init(fid: UInt32, path: Path, buf: ArrayList<Byte>) {
        this.fid = fid
        this.path = path
        this.buf = buf
    }
    
    public static func create(path: Path, fid: UInt32): VLogFile {
        return VLogFile(fid, path, ArrayList<Byte>())
    }
    
    public func write(entry: LogEntry): UInt32 {
        let encoded = entry.encode()
        let startOffset = UInt32(buf.size)
        
        for (b in encoded) {
            buf.add(b)
        }
        
        return UInt32(encoded.size)
    }
    
    public func read(offset: UInt32, len: UInt32): LogEntry {
        let start = Int64(offset)
        let end = start + Int64(len)
        let data = buf.toArray()[start..end]
        let (entry, _) = LogEntry.decode(data, 0)
        return entry
    }
    
    public func size(): UInt32 {
        return UInt32(buf.size)
    }
    
    public func close(): Unit {
    }
    
    public func sync(): Unit {
    }
    
    public func iterate(callback: (LogEntry, UInt32) -> Bool): Unit {
        var offset: UInt32 = 0
        let data = buf.toArray()
        let totalSize = Int64(data.size)
        
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