package badgercj.io_uring

/**
 * io_uring 批量写入优化
 * 
 * 核心优化：
 * 1. 全局 io_uring 实例复用
 * 2. 批量提交写入请求
 * 3. 统一等待完成
 */

import std.collection.*
import std.sync.*
import std.fs.*

/**
 * FileWriteRequest - 文件写入请求
 */
public struct FileWriteRequest {
    public let path: String
    public let data: Array<Byte>
    
    public init(path: String, data: Array<Byte>) {
        this.path = path
        this.data = data
    }
}

/**
 * FileWriteResult - 写入结果
 */
public struct FileWriteResult {
    public let path: String
    public let bytesWritten: Int64
    public let success: Bool
    public let error: ?String
    
    public init(path: String, bytesWritten: Int64, success: Bool, error!: ?String = None) {
        this.path = path
        this.bytesWritten = bytesWritten
        this.success = success
        this.error = error
    }
}

/**
 * IoUringPool - 全局 io_uring 实例池
 * 
 * 单例模式，复用 io_uring 实例
 */
@When[os == "Linux"]
public class IoUringPool {
    private let ring: IoUring
    private let lock: Mutex
    private var initialized: Bool
    
    private init() {
        this.ring = IoUring(entries: 4096)
        this.lock = Mutex()
        this.initialized = true
    }
    
    private static var instance: ?IoUringPool = None
    private static let instanceLock: Mutex = Mutex()
    
    public static func getInstance(): IoUringPool {
        instanceLock.lock()
        try {
            if (instance.isNone()) {
                instance = Some(IoUringPool())
            }
            instance ?? throw Exception("IoUringPool init failed")
        } finally {
            instanceLock.unlock()
        }
    }
    
    /**
     * writeFiles - 批量写入多个文件
     * 
     * 核心优化：一次提交所有写请求，统一等待完成
     */
    public func writeFiles(requests: ArrayList<FileWriteRequest>): ArrayList<FileWriteResult> {
        lock.lock()
        try {
            return doWriteFiles(requests)
        } finally {
            lock.unlock()
        }
    }
    
    private func doWriteFiles(requests: ArrayList<FileWriteRequest>): ArrayList<FileWriteResult> {
        let results = ArrayList<FileWriteResult>()
        
        if (requests.size == 0) {
            return results
        }
        
        unsafe {
            let fds = HashMap<String, Int32>()
            let pendingOps = ArrayList<PendingOp>()
            
            for (req in requests) {
                let pathHandle = acquireArrayRawData(req.path.toArray())
                let fd = open(pathHandle.pointer, O_WRONLY | O_CREAT | O_TRUNC, 0o644u32)
                releaseArrayRawData(pathHandle)
                
                if (fd < 0) {
                    results.add(FileWriteResult(req.path, 0, false, error: Some("Failed to open file")))
                    continue
                }
                
                fds.add(req.path, fd)
                
                if (req.data.size == 0) {
                    results.add(FileWriteResult(req.path, 0, true))
                    continue
                }
                
                let buffer = LibC.malloc<UInt8>(count: Int64(req.data.size))
                let dataHandle = acquireArrayRawData(req.data)
                memcpy(buffer, dataHandle.pointer, UIntNative(req.data.size))
                releaseArrayRawData(dataHandle)
                
                let sqe = io_uring_get_sqe(ring.getRingPtr())
                if (sqe.isNull()) {
                    LibC.free(buffer)
                    close(fd)
                    results.add(FileWriteResult(req.path, 0, false, error: Some("Failed to get SQE")))
                    continue
                }
                
                let opId = UInt64(pendingOps.size) + 1
                ioUringPrepWrite(sqe, fd, buffer, UInt32(req.data.size), 0)
                sqeSetUserData(sqe, opId)
                
                pendingOps.add(PendingOp(req.path, fd, buffer, Int64(req.data.size), opId))
            }
            
            if (pendingOps.size > 0) {
                ring.submitAndWait(UInt32(pendingOps.size))
                
                var completedCount: UInt32 = 0
                let cqePtrPtr = LibC.malloc<CPointer<Unit>>(count: 1)
                
                while (completedCount < UInt32(pendingOps.size)) {
                    let ret = __io_uring_get_cqe(ring.getRingPtr(), cqePtrPtr, 0, 1, CPointer<Unit>())
                    if (ret < 0) {
                        break
                    }
                    
                    let cqe = cqePtrPtr.read()
                    let userData = cqeGetUserData(cqe)
                    let res = cqeGetRes(cqe)
                    
                    ioUringCqeSeen(ring.getRingPtr(), cqe)
                    completedCount++
                    
                    let opIdx = Int64(userData) - 1
                    if (opIdx >= 0 && opIdx < pendingOps.size) {
                        let op = pendingOps[opIdx]
                        
                        if (res >= 0) {
                            results.add(FileWriteResult(op.path, Int64(res), true))
                        } else {
                            results.add(FileWriteResult(op.path, 0, false, error: Some("Write error: ${res}")))
                        }
                    }
                }
                
                LibC.free(cqePtrPtr)
                
                for (op in pendingOps) {
                    LibC.free(op.buffer)
                    close(op.fd)
                }
            }
            
            for ((_, fd) in fds) {
                if (fd >= 0) {
                    close(fd)
                }
            }
        }
        
        results
    }
    
    public func close(): Unit {
        lock.lock()
        try {
            if (initialized) {
                ring.close()
                initialized = false
            }
        } finally {
            lock.unlock()
        }
    }
}

@When[os == "Linux"]
private struct PendingOp {
    public let path: String
    public let fd: Int32
    public let buffer: CPointer<UInt8>
    public let size: Int64
    public let opId: UInt64
    
    public init(path: String, fd: Int32, buffer: CPointer<UInt8>, size: Int64, opId: UInt64) {
        this.path = path
        this.fd = fd
        this.buffer = buffer
        this.size = size
        this.opId = opId
    }
}

@When[os != "Linux"]
public class IoUringPool {
    public static func getInstance(): IoUringPool {
        throw Exception("io_uring not supported on this platform")
    }
    
    public func writeFiles(requests: ArrayList<FileWriteRequest>): ArrayList<FileWriteResult> {
        ArrayList<FileWriteResult>()
    }
    
    public func close(): Unit {}
}

/**
 * writeFilesBatch - 批量写入文件的便捷函数
 */
@When[os == "Linux"]
public func writeFilesBatch(requests: ArrayList<FileWriteRequest>, useIoUring!: Bool = true): ArrayList<FileWriteResult> {
    if (useIoUring) {
        return IoUringPool.getInstance().writeFiles(requests)
    }
    syncWriteFilesFallback(requests)
}

@When[os != "Linux"]
public func writeFilesBatch(requests: ArrayList<FileWriteRequest>, useIoUring!: Bool = true): ArrayList<FileWriteResult> {
    syncWriteFilesFallback(requests)
}

private func syncWriteFilesFallback(requests: ArrayList<FileWriteRequest>): ArrayList<FileWriteResult> {
    let results = ArrayList<FileWriteResult>()
    for (req in requests) {
        try {
            let f = File(Path(req.path), Write)
            f.write(req.data)
            f.close()
            results.add(FileWriteResult(req.path, Int64(req.data.size), true))
        } catch (e: Exception) {
            results.add(FileWriteResult(req.path, 0, false, error: Some(e.message)))
        }
    }
    results
}