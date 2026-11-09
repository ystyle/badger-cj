package badgercj.db

import std.collection.*
import badgercj.table.*

public interface TableInterface {
    func getId(): UInt64
    func smallest(): Array<Byte>
    func biggest(): Array<Byte>
    func get(key: Array<Byte>, readTs: UInt64): Option<ValueStruct>
    func size(): Int64
    /** 表数据字节数（on-disk 大小） */
    func dataSize(): Int64
    func getMaxVersion(): UInt64
    func keyCount(): UInt32
    func uncompressedSize(): Int64
    func offsetsLength(): Int64
    func getOffsetKey(idx: Int64): Array<Byte>
    func keySplits(n: Int64, prefix: Array<Byte>): ArrayList<Array<Byte>>
    func newIterator(): TableIter
    /**
     * 释放底层资源（磁盘表解除映射）。表不可变，关闭后不可再读。
     * 约定：读块是复制语义，因此「表从 LevelHandler 摘除后即可 close」，
     * 无需引用计数；Windows 上必须先 close 再 unlink 表文件。
     */
    func close(): Unit
    /** 表数据是否由只读映射承载（诊断/测试用） */
    func isMmapBacked(): Bool
}