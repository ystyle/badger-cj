package badgercj.vlog

import std.collection.*

/**
 * ValueLog - Value Log 文件管理
 * 
 * 存储大值的分离日志文件
 */
public class ValueLog {
    private let buf: ArrayList<Byte>
    private var offset: UInt32
    
    public init(initialSize!: Int64 = 1024 * 1024) {
        this.buf = ArrayList<Byte>()
        this.offset = 0
    }
    
    /**
     * 写入 Entry
     * 
     * 返回：ValuePointer
     */
    public func write(entry: LogEntry): ValuePointer {
        let currentOffset = offset
        let encoded = entry.encode()
        
        for (b in encoded) {
            buf.add(b)
        }
        
        offset += UInt32(encoded.size)
        
        return ValuePointer(0, UInt32(encoded.size), currentOffset)
    }
    
    /**
     * 读取 Entry
     */
    public func read(vp: ValuePointer): LogEntry {
        let (entry, _) = LogEntry.decode(buf.toArray(), Int64(vp.offset))
        return entry
    }
    
    /**
     * 获取当前大小
     */
    public func size(): UInt32 {
        return offset
    }
    
    /**
     * 获取所有数据
     */
    public func data(): Array<Byte> {
        return buf.toArray()
    }
}

/**
 * ValuePointer - 指向 Value Log 中的值
 */
public struct ValuePointer {
    public let fid: UInt32
    public let len: UInt32
    public let offset: UInt32
    
    public init(fid: UInt32, len: UInt32, offset: UInt32) {
        this.fid = fid
        this.len = len
        this.offset = offset
    }
}
