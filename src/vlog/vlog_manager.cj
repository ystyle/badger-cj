package badgercj.vlog

import std.collection.*
import std.fs.*
import std.io.*
import std.sync.*
import badgercj.table.*
import badgercj.table.*

/**
 * VLogManager - Value Log 管理器
 * 
 * 管理多个 VLog 文件，支持大值分离存储
 */
public class VLogManager {
    private let dir: Path
    private let opt: VLogOptions
    private let lock: Mutex
    
    private var files: HashMap<UInt32, VLogFile>
    private var maxFid: UInt32
    private var currentFile: VLogFile
    private var offset: UInt32
    
    public init(dir: Path, opt!: VLogOptions = VLogOptions()) {
        this.dir = dir
        this.opt = opt
        this.lock = Mutex()
        this.files = HashMap<UInt32, VLogFile>()
        this.maxFid = 0
        this.offset = 0
        
        let newFile = VLogFile.create(Path("./0.vlog"), 0)
        this.currentFile = newFile
        this.files[0] = newFile
    }
    
    public func write(entry: LogEntry): ValuePointer {
        synchronized (lock) {
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
            let totalSize = file.size()
            
            if (totalSize == 0) {
                return 0.0
            }
            
            return getDiscardRatioInternal(fid)
        }
    }
    
    private func getDiscardRatioInternal(fid: UInt32): Float64 {
        if (!files.contains(fid)) {
            return 0.0
        }
        return 0.5
    }
    
    public func runGC(discardRatio: Float64): Bool {
        synchronized (lock) {
            var targetFid: UInt32 = 0
            var maxRatio: Float64 = 0.0
            
            for ((fid, _) in files) {
                let ratio = getDiscardRatioInternal(fid)
                if (ratio > discardRatio && ratio > maxRatio) {
                    maxRatio = ratio
                    targetFid = fid
                }
            }
            
            if (targetFid == 0 || targetFid == currentFile.fid) {
                return false
            }
            
            files.remove(targetFid)
            return true
        }
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
        // TODO: 刷新到文件
    }
}

/**
 * VLogOptions - VLog 配置
 */
public struct VLogOptions {
    public var maxFileSize: UInt32 = 1024 * 1024 * 1024  // 1GB
    public var valueThreshold: Int64 = 1024              // 1KB
    
    public init() {}
}