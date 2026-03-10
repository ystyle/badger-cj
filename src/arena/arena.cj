/**
 * Arena 内存分配器
 * 
 * Arena 是一个固定大小的内存池，用于 Skiplist 的高效内存分配
 * 特点：
 * - 预分配固定大小，不扩容
 * - 原子性分配，支持并发
 * - 支持内存对齐
 * - append-only，不释放内存
 */
package badgercj.arena

import std.sync.*

// Arena 常量
public const MAX_HEIGHT: Int64 = 20          // Skiplist 最大高度
public const OFFSET_SIZE: Int64 = 4          // 偏移量大小（UInt32）
public const NODE_ALIGN: Int64 = 8           // 节点对齐大小
public const MAX_NODE_SIZE: Int64 = 104      // 最大节点大小

/**
 * Arena 内存池
 * 
 * 使用固定大小的 byte 数组作为底层存储
 * 使用 AtomicUInt32 实现并发安全的分配
 */
public class Arena {
    // 底层存储（固定大小）
    private let buf: Array<Byte>
    
    // 原子指针（当前分配位置）
    private let n: AtomicUInt32
    
    // Arena 大小
    public let size: Int64
    
    /**
     * 创建指定大小的 Arena
     */
    public init(size: Int64) {
        this.buf = Array<Byte>(size, repeat: 0)
        this.n = AtomicUInt32(1)  // 0 保留为 null 指针
        this.size = size
    }
    
    /**
     * 分配指定大小的空间
     * 
     * 返回：起始偏移量
     */
    public func allocate(sz: UInt32): UInt32 {
        let offset = n.fetchAdd(sz)  // 返回旧值
        let newOffset = offset + sz
        
        // 检查溢出
        if (newOffset > UInt32(buf.size)) {
            throw Exception("Arena overflow: requested ${sz}, total size ${buf.size}")
        }
        
        return offset
    }
    
    /**
     * 分配节点空间（支持对齐）
     * 
     * 参数：
     * - height: Skiplist 节点高度
     * 
     * 返回：对齐后的偏移量
     */
    public func putNode(height: Int64): UInt32 {
        // 计算节点大小
        let unusedSize = (MAX_HEIGHT - height) * OFFSET_SIZE
        let l = UInt32(MAX_NODE_SIZE - unusedSize + NODE_ALIGN)
        
        // 原子性分配
        let offset = n.fetchAdd(l)
        let newOffset = offset + l
        
        // 检查溢出
        if (newOffset > UInt32(buf.size)) {
            throw Exception("Arena overflow: cannot allocate node with height ${height}")
        }
        
        // 返回对齐的偏移量
        let aligned = (offset + UInt32(NODE_ALIGN)) & UInt32(0xFFFFFFF8)  // 8字节对齐
        return aligned
    }
    
    /**
     * 存储字节数组
     * 
     * 返回：起始偏移量
     */
    public func putBytes(data: Array<Byte>): UInt32 {
        let l = UInt32(data.size)
        let offset = allocate(l)
        
        // 写入数据
        for (i in 0..data.size) {
            buf[Int64(offset) + i] = data[i]
        }
        
        return offset
    }
    
    /**
     * 获取字节数组
     */
    public func getBytes(offset: UInt32, size: UInt16): Array<Byte> {
        let result = Array<Byte>(Int64(size), repeat: 0)
        
        for (i in 0..Int64(size)) {
            result[i] = buf[Int64(offset) + i]
        }
        
        return result
    }
    
    /**
     * 写入单个字节
     */
    public func putByte(b: Byte, offset: UInt32): Unit {
        buf[Int64(offset)] = b
    }
    
    /**
     * 读取单个字节
     */
    public func getByte(offset: UInt32): Byte {
        return buf[Int64(offset)]
    }
    
    /**
     * 写入 UInt16（Little-Endian）
     */
    public func putU16(value: UInt16, offset: UInt32): Unit {
        buf[Int64(offset)] = UInt8(value & 0xFFu16)
        buf[Int64(offset) + 1] = UInt8((value >> 8u16) & 0xFFu16)
    }
    
    /**
     * 读取 UInt16（Little-Endian）
     */
    public func getU16(offset: UInt32): UInt16 {
        return UInt16(buf[Int64(offset)]) |
               (UInt16(buf[Int64(offset) + 1]) << 8u16)
    }
    
    /**
     * 写入 UInt32（Little-Endian）
     */
    public func putU32(value: UInt32, offset: UInt32): Unit {
        buf[Int64(offset)] = UInt8(value & 0xFFu32)
        buf[Int64(offset) + 1] = UInt8((value >> 8u32) & 0xFFu32)
        buf[Int64(offset) + 2] = UInt8((value >> 16u32) & 0xFFu32)
        buf[Int64(offset) + 3] = UInt8((value >> 24u32) & 0xFFu32)
    }
    
    /**
     * 读取 UInt32（Little-Endian）
     */
    public func getU32(offset: UInt32): UInt32 {
        return UInt32(buf[Int64(offset)]) |
               (UInt32(buf[Int64(offset) + 1]) << 8u32) |
               (UInt32(buf[Int64(offset) + 2]) << 16u32) |
               (UInt32(buf[Int64(offset) + 3]) << 24u32)
    }
    
    /**
     * 写入 UInt64（Little-Endian）
     */
    public func putU64(value: UInt64, offset: UInt32): Unit {
        buf[Int64(offset)] = UInt8(value & 0xFFu64)
        buf[Int64(offset) + 1] = UInt8((value >> 8u64) & 0xFFu64)
        buf[Int64(offset) + 2] = UInt8((value >> 16u64) & 0xFFu64)
        buf[Int64(offset) + 3] = UInt8((value >> 24u64) & 0xFFu64)
        buf[Int64(offset) + 4] = UInt8((value >> 32u64) & 0xFFu64)
        buf[Int64(offset) + 5] = UInt8((value >> 40u64) & 0xFFu64)
        buf[Int64(offset) + 6] = UInt8((value >> 48u64) & 0xFFu64)
        buf[Int64(offset) + 7] = UInt8((value >> 56u64) & 0xFFu64)
    }
    
    /**
     * 读取 UInt64（Little-Endian）
     */
    public func getU64(offset: UInt32): UInt64 {
        return UInt64(buf[Int64(offset)]) |
               (UInt64(buf[Int64(offset) + 1]) << 8u64) |
               (UInt64(buf[Int64(offset) + 2]) << 16u64) |
               (UInt64(buf[Int64(offset) + 3]) << 24u64) |
               (UInt64(buf[Int64(offset) + 4]) << 32u64) |
               (UInt64(buf[Int64(offset) + 5]) << 40u64) |
               (UInt64(buf[Int64(offset) + 6]) << 48u64) |
               (UInt64(buf[Int64(offset) + 7]) << 56u64)
    }
    
    /**
     * 读取 Int64（Little-Endian）
     */
    public func getI64(offset: UInt32): Int64 {
        let v = UInt64(buf[Int64(offset)]) |
               (UInt64(buf[Int64(offset) + 1]) << 8u64) |
               (UInt64(buf[Int64(offset) + 2]) << 16u64) |
               (UInt64(buf[Int64(offset) + 3]) << 24u64) |
               (UInt64(buf[Int64(offset) + 4]) << 32u64) |
               (UInt64(buf[Int64(offset) + 5]) << 40u64) |
               (UInt64(buf[Int64(offset) + 6]) << 48u64) |
               (UInt64(buf[Int64(offset) + 7]) << 56u64)
        return Int64(v)
    }
    
    /**
     * 写入 Int64（Little-Endian）
     */
    public func putI64(value: Int64, offset: UInt32): Unit {
        let v = UInt64(value)
        buf[Int64(offset)] = UInt8(v & 0xFFu64)
        buf[Int64(offset) + 1] = UInt8((v >> 8u64) & 0xFFu64)
        buf[Int64(offset) + 2] = UInt8((v >> 16u64) & 0xFFu64)
        buf[Int64(offset) + 3] = UInt8((v >> 24u64) & 0xFFu64)
        buf[Int64(offset) + 4] = UInt8((v >> 32u64) & 0xFFu64)
        buf[Int64(offset) + 5] = UInt8((v >> 40u64) & 0xFFu64)
        buf[Int64(offset) + 6] = UInt8((v >> 48u64) & 0xFFu64)
        buf[Int64(offset) + 7] = UInt8((v >> 56u64) & 0xFFu64)
    }
    
    /**
     * 获取当前已使用的大小
     */
    public func usedSize(): UInt32 {
        return n.load()
    }
    
    /**
     * 获取剩余可用大小
     */
    public func remainingSize(): UInt32 {
        return UInt32(buf.size) - n.load()
    }
}