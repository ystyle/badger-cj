package badgercj.io_uring

/**
 * io_uring 跨平台支持
 * 
 * - Linux: 使用内核 io_uring 实现
 * - 其他平台: 不可用
 */

import std.collection.*

/**
 * IoUringException - io_uring 相关异常
 */
public class IoUringException <: Exception {
    public let errorCode: Int32
    
    public init(message: String, errorCode!: Int32 = 0) {
        super(message)
        this.errorCode = errorCode
    }
}

/**
 * IoUringInterface - io_uring 跨平台接口
 */
public interface IoUringInterface {
    func write(data: Array<Byte>): Unit
    func sync(): Unit
    func close(): Unit
}

/**
 * createIoUringWriter - 创建 io_uring 写入器
 * 
 * 返回 None 如果平台不支持
 */
@When[os == "Linux"]
public func createIoUringWriter(path: String, entries!: UInt32 = 256, maxPending!: UInt32 = 32): ?IoUringInterface {
    if (!checkIoUringAvailable()) {
        return None
    }
    Some(IoUringFileWriter(path, entries: entries, maxPending: maxPending))
}

@When[os != "Linux"]
public func createIoUringWriter(path: String, entries!: UInt32 = 256, maxPending!: UInt32 = 32): ?IoUringInterface {
    None
}

/**
 * checkIoUringAvailable - 检查 io_uring 是否可用
 */
@When[os == "Linux"]
private func checkIoUringAvailable(): Bool {
    unsafe {
        let ring = CPointer<Unit>(LibC.malloc<UInt8>(count: 256))
        let ret = io_uring_queue_init(1, ring, 0)
        var result = false
        if (ret >= 0) {
            io_uring_queue_exit(ring)
            result = true
        }
        LibC.free(ring)
        result
    }
}

@When[os != "Linux"]
private func checkIoUringAvailable(): Bool {
    false
}

@When[os == "Linux"]
public class IoUring {
    private let ringPtr: CPointer<Unit>
    private var closed: Bool = false
    
    public init(entries!: UInt32 = 256) {
        this.ringPtr = unsafe { CPointer<Unit>(LibC.malloc<UInt8>(count: 256)) }
        this.closed = false
        
        let ret = unsafe { io_uring_queue_init(entries, ringPtr, 0) }
        if (ret < 0) {
            unsafe { LibC.free(ringPtr) }
            throw IoUringException("io_uring_queue_init failed", errorCode: ret)
        }
    }
    
    public func submit(): Unit {
        checkClosed()
        unsafe {
            let ret = io_uring_submit(ringPtr)
            if (ret < 0) {
                throw IoUringException("submit failed", errorCode: ret)
            }
        }
    }
    
    public func submitAndWait(waitNr: UInt32): Unit {
        checkClosed()
        unsafe {
            let ret = io_uring_submit_and_wait(ringPtr, waitNr)
            if (ret < 0) {
                throw IoUringException("submit_and_wait failed", errorCode: ret)
            }
        }
    }
    
    public func close(): Unit {
        if (closed) { return }
        closed = true
        unsafe {
            io_uring_queue_exit(ringPtr)
            LibC.free(ringPtr)
        }
    }
    
    public func isClosed(): Bool { closed }
    
    private func checkClosed(): Unit {
        if (closed) {
            throw IoUringException("io_uring is closed")
        }
    }
    
    internal func getRingPtr(): CPointer<Unit> { ringPtr }
}

@When[os == "Linux"]
private class PendingWrite {
    public let buffer: CPointer<UInt8>
    public let size: Int64
    
    public init(buffer: CPointer<UInt8>, size: Int64) {
        this.buffer = buffer
        this.size = size
    }
}

@When[os == "Linux"]
public class IoUringFileWriter <: IoUringInterface {
    private let ring: IoUring
    private let fd: Int32
    private let maxPending: UInt32
    private var writeOffset: UInt64 = 0
    private var pendingCount: UInt32 = 0
    private var closed: Bool = false
    
    private let pendingWrites: HashMap<UInt64, PendingWrite> = HashMap<UInt64, PendingWrite>()
    
    public init(path: String, entries!: UInt32 = 256, maxPending!: UInt32 = 32) {
        this.ring = IoUring(entries: entries)
        this.maxPending = maxPending
        this.closed = false
        
        var localFd: Int32 = -1
        unsafe {
            let pathHandle = acquireArrayRawData(path.toArray())
            localFd = open(pathHandle.pointer, O_WRONLY | O_CREAT | O_TRUNC, 0o644u32)
            releaseArrayRawData(pathHandle)
        }
        
        if (localFd < 0) {
            ring.close()
            throw IoUringException("Failed to open file: ${path}")
        }
        this.fd = localFd
    }
    
    public func write(data: Array<Byte>): Unit {
        checkClosed()
        
        if (data.size == 0) {
            return
        }
        
        if (pendingCount >= maxPending) {
            waitForSomeCompletions(maxPending / 2)
        }
        
        unsafe {
            let buffer = LibC.malloc<UInt8>(count: Int64(data.size))
            
            let handle = acquireArrayRawData(data)
            memcpy(buffer, handle.pointer, UIntNative(data.size))
            releaseArrayRawData(handle)
            
            var sqe = io_uring_get_sqe(ring.getRingPtr())
            if (sqe.isNull()) {
                submitAndWaitForCompletions()
                
                sqe = io_uring_get_sqe(ring.getRingPtr())
                if (sqe.isNull()) {
                    LibC.free(buffer)
                    throw IoUringException("Failed to get SQE after submit")
                }
            }
            
            let currentOffset = writeOffset
            ioUringPrepWrite(sqe, fd, buffer, UInt32(data.size), currentOffset)
            sqeSetUserData(sqe, currentOffset)
            
            pendingWrites.add(currentOffset, PendingWrite(buffer, Int64(data.size)))
            
            writeOffset += UInt64(data.size)
            pendingCount++
        }
    }
    
    public func sync(): Unit {
        checkClosed()
        
        waitForAllCompletions()
        
        unsafe {
            let sqe = io_uring_get_sqe(ring.getRingPtr())
            if (sqe.isNull()) {
                throw IoUringException("Failed to get SQE for sync")
            }
            
            ioUringPrepFsync(sqe, fd, IORING_FSYNC_DATASYNC)
            sqeSetUserData(sqe, 0xFFFFFFFF_FFFFFFFFu64)
            
            ring.submitAndWait(1)
            
            let cqePtrPtr = LibC.malloc<CPointer<Unit>>(count: 1)
            let ret = __io_uring_get_cqe(ring.getRingPtr(), cqePtrPtr, 0, 1, CPointer<Unit>())
            if (ret < 0) {
                LibC.free(cqePtrPtr)
                throw IoUringException("sync wait failed", errorCode: ret)
            }
            let cqe = cqePtrPtr.read()
            LibC.free(cqePtrPtr)
            ioUringCqeSeen(ring.getRingPtr(), cqe)
        }
    }
    
    public func close(): Unit {
        if (closed) { return }
        
        waitForAllCompletions()
        
        unsafe { close(fd) }
        ring.close()
        closed = true
    }
    
    private func waitForAllCompletions(): Unit {
        while (pendingCount > 0) {
            unsafe {
                ring.submitAndWait(1)
                reapCompletions()
            }
        }
    }
    
    private func waitForSomeCompletions(count: UInt32): Unit {
        if (count == 0 || pendingCount == 0) {
            return
        }
        
        unsafe {
            ring.submitAndWait(count)
            reapCompletions()
        }
    }
    
    private func submitAndWaitForCompletions(): Unit {
        if (pendingCount == 0) {
            return
        }
        
        unsafe {
            ring.submitAndWait(pendingCount)
            reapCompletions()
        }
    }
    
    private unsafe func reapCompletions(): Unit {
        let cqePtrPtr = LibC.malloc<CPointer<Unit>>(count: 1)
        
        while (true) {
            let ret = __io_uring_get_cqe(ring.getRingPtr(), cqePtrPtr, 0, 0, CPointer<Unit>())
            if (ret != 0) {
                break
            }
            
            let cqe = cqePtrPtr.read()
            let userData = cqeGetUserData(cqe)
            let res = cqeGetRes(cqe)
            
            ioUringCqeSeen(ring.getRingPtr(), cqe)
            
            if (userData != 0xFFFFFFFF_FFFFFFFFu64) {
                freePendingWrite(userData)
                
                if (res < 0) {
                    LibC.free(cqePtrPtr)
                    throw IoUringException("I/O error (res=${res})", errorCode: res)
                }
            }
        }
        
        LibC.free(cqePtrPtr)
    }
    
    private func checkClosed(): Unit {
        if (closed) {
            throw IoUringException("Writer is closed")
        }
    }
    
    private func freePendingWrite(offset: UInt64): Unit {
        match (pendingWrites.get(offset)) {
            case Some(pending) => 
                unsafe { LibC.free(pending.buffer) }
                pendingWrites.remove(offset)
                pendingCount--
            case None => ()
        }
    }
}