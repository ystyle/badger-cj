package badgercj.io_uring

/**
 * io_uring FFI 绑定
 * 
 * 仅在 Linux 5.1+ 上可用，需要链接 liburing
 * 
 * 注意：liburing 中很多函数是 static inline，不能通过 FFI 调用
 * 这些函数需要手动实现
 */

// ========== Linux 平台专用 ==========

// SQE (Submission Queue Entry) - 64 字节
@When[os == "Linux"]
@C
public struct io_uring_sqe {
    var opcode: UInt8 = 0
    var flags: UInt8 = 0
    var ioprio: UInt16 = 0
    var fd: Int32 = 0
    var off: UInt64 = 0
    var addr: UInt64 = 0
    var len: UInt32 = 0
    var rw_flags: UInt32 = 0
    var user_data: UInt64 = 0
    var buf_index: UInt16 = 0
    var personality: UInt16 = 0
    var splice_fd_in: Int32 = 0
    var addr3: UInt64 = 0
    var pad: UInt64 = 0
}

@When[os == "Linux"]
@C
public struct io_uring_cqe {
    var user_data: UInt64 = 0
    var res: Int32 = 0
    var flags: UInt32 = 0
}

@When[os == "Linux"]
@C
public struct iovec {
    var iov_base: CPointer<UInt8> = CPointer<UInt8>()
    var iov_len: UIntNative = 0
}

@When[os == "Linux"]
public const IORING_OP_NOP: UInt8 = 0

@When[os == "Linux"]
public const IORING_OP_READV: UInt8 = 7

@When[os == "Linux"]
public const IORING_OP_WRITEV: UInt8 = 8

@When[os == "Linux"]
public const IORING_OP_FSYNC: UInt8 = 9

@When[os == "Linux"]
public const IORING_OP_READ: UInt8 = 22

@When[os == "Linux"]
public const IORING_OP_WRITE: UInt8 = 23

@When[os == "Linux"]
public const IORING_FSYNC_DATASYNC: UInt32 = 1

@When[os == "Linux"]
public const IORING_SETUP_IOPOLL: UInt32 = 1

@When[os == "Linux"]
public const IORING_SETUP_SQPOLL: UInt32 = 2

@When[os == "Linux"]
public const IORING_SETUP_SQ_AFF: UInt32 = 4

// liburing 导出的 FFI 函数
@When[os == "Linux"]
@FastNative
foreign func io_uring_queue_init(entries: UInt32, ring: CPointer<Unit>, flags: UInt32): Int32

@When[os == "Linux"]
@FastNative
foreign func io_uring_queue_exit(ring: CPointer<Unit>): Unit

@When[os == "Linux"]
@FastNative
foreign func io_uring_get_sqe(ring: CPointer<Unit>): CPointer<Unit>

@When[os == "Linux"]
@FastNative
foreign func io_uring_submit(ring: CPointer<Unit>): Int32

@When[os == "Linux"]
@FastNative
foreign func io_uring_submit_and_wait(ring: CPointer<Unit>, wait_nr: UInt32): Int32

@When[os == "Linux"]
@FastNative
foreign func __io_uring_get_cqe(ring: CPointer<Unit>, cqe_ptr: CPointer<CPointer<Unit>>, submit: UInt32, wait_nr: UInt32, sigmask: CPointer<Unit>): Int32

// POSIX 文件操作
@When[os == "Linux"]
@FastNative
foreign func open(pathname: CPointer<UInt8>, flags: Int32, mode: UInt32): Int32

@When[os == "Linux"]
@FastNative
foreign func close(fd: Int32): Int32

// 内存操作
@When[os == "Linux"]
@FastNative
foreign func memcpy(dest: CPointer<UInt8>, src: CPointer<UInt8>, n: UIntNative): CPointer<UInt8>

@When[os == "Linux"]
public const O_RDONLY: Int32 = 0

@When[os == "Linux"]
public const O_WRONLY: Int32 = 1

@When[os == "Linux"]
public const O_RDWR: Int32 = 2

@When[os == "Linux"]
public const O_CREAT: Int32 = 64

@When[os == "Linux"]
public const O_TRUNC: Int32 = 512

@When[os == "Linux"]
public const O_DIRECT: Int32 = 16384

@When[os == "Linux"]
public const O_DSYNC: Int32 = 4096

// ========== 手动实现的 inline 函数替代 ==========

@When[os == "Linux"]
public unsafe func ioUringPrepNop(sqe: CPointer<Unit>): Unit {
    let sqePtr = CPointer<io_uring_sqe>(sqe)
    var sqeStruct = io_uring_sqe()
    sqeStruct.opcode = IORING_OP_NOP
    sqePtr.write(sqeStruct)
}

@When[os == "Linux"]
public unsafe func ioUringPrepWritev(sqe: CPointer<Unit>, fd: Int32, iovecs: CPointer<iovec>, nrVecs: UInt32, offset: UInt64): Unit {
    let sqePtr = CPointer<io_uring_sqe>(sqe)
    var sqeStruct = io_uring_sqe()
    sqeStruct.opcode = IORING_OP_WRITEV
    sqeStruct.fd = fd
    sqeStruct.off = offset
    sqeStruct.addr = UInt64(iovecs.toUIntNative())
    sqeStruct.len = nrVecs
    sqePtr.write(sqeStruct)
}

@When[os == "Linux"]
public unsafe func ioUringPrepReadv(sqe: CPointer<Unit>, fd: Int32, iovecs: CPointer<iovec>, nrVecs: UInt32, offset: UInt64): Unit {
    let sqePtr = CPointer<io_uring_sqe>(sqe)
    var sqeStruct = io_uring_sqe()
    sqeStruct.opcode = IORING_OP_READV
    sqeStruct.fd = fd
    sqeStruct.off = offset
    sqeStruct.addr = UInt64(iovecs.toUIntNative())
    sqeStruct.len = nrVecs
    sqePtr.write(sqeStruct)
}

@When[os == "Linux"]
public unsafe func ioUringPrepWrite(sqe: CPointer<Unit>, fd: Int32, buf: CPointer<UInt8>, nbytes: UInt32, offset: UInt64): Unit {
    let sqePtr = CPointer<io_uring_sqe>(sqe)
    var sqeStruct = io_uring_sqe()
    sqeStruct.opcode = IORING_OP_WRITE
    sqeStruct.fd = fd
    sqeStruct.off = offset
    sqeStruct.addr = UInt64(buf.toUIntNative())
    sqeStruct.len = nbytes
    sqePtr.write(sqeStruct)
}

@When[os == "Linux"]
public unsafe func ioUringPrepRead(sqe: CPointer<Unit>, fd: Int32, buf: CPointer<UInt8>, nbytes: UInt32, offset: UInt64): Unit {
    let sqePtr = CPointer<io_uring_sqe>(sqe)
    var sqeStruct = io_uring_sqe()
    sqeStruct.opcode = IORING_OP_READ
    sqeStruct.fd = fd
    sqeStruct.off = offset
    sqeStruct.addr = UInt64(buf.toUIntNative())
    sqeStruct.len = nbytes
    sqePtr.write(sqeStruct)
}

@When[os == "Linux"]
public unsafe func ioUringPrepFsync(sqe: CPointer<Unit>, fd: Int32, fsyncFlags: UInt32): Unit {
    let sqePtr = CPointer<io_uring_sqe>(sqe)
    var sqeStruct = io_uring_sqe()
    sqeStruct.opcode = IORING_OP_FSYNC
    sqeStruct.fd = fd
    sqeStruct.rw_flags = fsyncFlags
    sqePtr.write(sqeStruct)
}

@When[os == "Linux"]
public unsafe func sqeSetUserData(sqe: CPointer<Unit>, data: UInt64): Unit {
    let sqePtr = CPointer<io_uring_sqe>(sqe)
    var sqeStruct = sqePtr.read()
    sqeStruct.user_data = data
    sqePtr.write(sqeStruct)
}

@When[os == "Linux"]
public unsafe func cqeGetUserData(cqe: CPointer<Unit>): UInt64 {
    let cqePtr = CPointer<io_uring_cqe>(cqe)
    cqePtr.read().user_data
}

@When[os == "Linux"]
public unsafe func cqeGetRes(cqe: CPointer<Unit>): Int32 {
    let cqePtr = CPointer<io_uring_cqe>(cqe)
    cqePtr.read().res
}

@When[os == "Linux"]
public unsafe func ioUringWaitCqe(ring: CPointer<Unit>, cqePtr: CPointer<CPointer<Unit>>): Int32 {
    __io_uring_get_cqe(ring, cqePtr, 1, 1, CPointer<Unit>())
}

@When[os == "Linux"]
public unsafe func ioUringPeekCqe(ring: CPointer<Unit>, cqePtr: CPointer<CPointer<Unit>>): Int32 {
    __io_uring_get_cqe(ring, cqePtr, 0, 0, CPointer<Unit>())
}

// ========== 内部结构布局 ==========

@When[os == "Linux"]
@C
struct io_uring_cq_layout {
    var khead: CPointer<UInt32> = CPointer<UInt32>()
    var ktail: CPointer<UInt32> = CPointer<UInt32>()
    var kring_mask: CPointer<UInt32> = CPointer<UInt32>()
    var kring_entries: CPointer<UInt32> = CPointer<UInt32>()
    var kflags: CPointer<UInt32> = CPointer<UInt32>()
    var koverflow: CPointer<UInt32> = CPointer<UInt32>()
    var cqes: CPointer<io_uring_cqe> = CPointer<io_uring_cqe>()
    var ring_sz: UIntNative = 0
    var ring_ptr: CPointer<Unit> = CPointer<Unit>()
    var ring_mask: UInt32 = 0
    var ring_entries: UInt32 = 0
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
}

@When[os == "Linux"]
@C
struct io_uring_sq_layout {
    var khead: CPointer<UInt32> = CPointer<UInt32>()
    var ktail: CPointer<UInt32> = CPointer<UInt32>()
    var kring_mask: CPointer<UInt32> = CPointer<UInt32>()
    var kring_entries: CPointer<UInt32> = CPointer<UInt32>()
    var kflags: CPointer<UInt32> = CPointer<UInt32>()
    var kdropped: CPointer<UInt32> = CPointer<UInt32>()
    var array: CPointer<UInt32> = CPointer<UInt32>()
    var sqes: CPointer<io_uring_sqe> = CPointer<io_uring_sqe>()
    var sqe_head: UInt32 = 0
    var sqe_tail: UInt32 = 0
    var ring_sz: UIntNative = 0
    var ring_ptr: CPointer<Unit> = CPointer<Unit>()
    var ring_mask: UInt32 = 0
    var ring_entries: UInt32 = 0
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
}

@When[os == "Linux"]
@C
struct io_uring_layout {
    var sq: io_uring_sq_layout = io_uring_sq_layout()
    var cq: io_uring_cq_layout = io_uring_cq_layout()
    var flags: UInt32 = 0
    var ring_fd: Int32 = 0
    var features: UInt32 = 0
    var enter_ring_fd: Int32 = 0
    var int_flags: UInt8 = 0
    var pad0: UInt8 = 0
    var pad1: UInt8 = 0
    var pad2: UInt8 = 0
    var pad3: UInt32 = 0
}

@When[os == "Linux"]
public unsafe func ioUringCqeSeen(ring: CPointer<Unit>, cqe: CPointer<Unit>): Unit {
    if (cqe.isNull()) {
        return
    }
    
    let ringPtr = CPointer<io_uring_layout>(ring)
    let ringStruct = ringPtr.read()
    let kheadPtr = ringStruct.cq.khead
    
    let currentHead = kheadPtr.read()
    kheadPtr.write(currentHead + 1)
}