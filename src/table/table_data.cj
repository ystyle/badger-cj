package badgercj.table

import std.fs.*
import mmapcj.*

/**
 * TableData - 表数据的存放抽象。
 *
 * 把「表数据放在哪」与 `Table` 的读逻辑解耦：
 * - 内存模式 / 测试 / 构建产物：`MemoryTableData`（持有 `Array<Byte>`，与改造前语义一致）；
 * - 磁盘模式：`MmapTableData`（只读映射，数据位于页缓存而非 GC 堆，物理页可被 OS 回收）。
 *
 * 读接口是**复制语义**（返回新数组），因此调用方读块后不再持有表数据——
 * 这让「表从 LevelHandler 摘除后即可释放底层资源」成为安全操作，无需引用计数。
 */
protected interface TableData {
    /** 读取 `[offset, offset+len)` 的字节（复制语义） */
    func read(offset: Int64, len: Int64): Array<Byte>
    /** 数据总长度（即表文件字节数） */
    func size(): Int64
    /** 释放底层资源（内存实现为空操作） */
    func close(): Unit
}

/** 内存表数据：直接持有 `Array<Byte>`（InMemory 模式 / 测试 / flush 构建产物） */
protected class MemoryTableData <: TableData {
    private let data: Array<Byte>

    public init(data: Array<Byte>) {
        this.data = data
    }

    public func read(offset: Int64, len: Int64): Array<Byte> {
        data[offset..(offset + len)]
    }

    public func size(): Int64 {
        Int64(data.size)
    }

    public func close(): Unit {}

    /** 直取底层数组（零拷贝），供需要全量视图的内部逻辑使用 */
    public func raw(): Array<Byte> {
        data
    }
}

/**
 * 磁盘表数据：只读映射（数据位于页缓存而非 GC 堆，物理页由 OS 按访问加载、可回收）。
 *
 * unlink 后映射依然有效——这让「compaction 删除旧表文件」与「并发读者/迭代器读该表」
 * 天然安全，无需引用计数。Windows 上被映射文件不能删除，需**先 close 再 unlink**。
 */
protected class MmapTableData <: TableData {
    private let mmap: MmapFile

    /** @param path 表文件路径（调用方保证文件存在且不会被并发改写——表文件不可变） */
    public init(path: String) {
        let f = File(Path(path), Read)
        let size = f.length
        f.close()
        this.mmap = MmapFile(path, size, readOnly: true)
    }

    public func read(offset: Int64, len: Int64): Array<Byte> {
        mmap.read(offset, len)
    }

    public func size(): Int64 {
        mmap.size
    }

    public func close(): Unit {
        mmap.close()
    }
}
