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
     * 释放持有者引用。表不可变，但摘除不等于没有读者：已在读的迭代器还要读完它那一份
     * 数据，因此引用计数归零才真正解映射、才删待删文件（见 Table.decrRef）。
     */
    func close(): Unit
    /** 强制释放（数据库关闭用）：忽略尚未归还的读者引用 */
    func closeForce(): Unit
    /** 标记表文件在最后一个引用释放时删除（compaction 换表用） */
    func markForDeletion(path: String): Unit
    /** 当前引用计数（诊断/测试用） */
    func refCount(): Int64
    /** 表数据是否由只读映射承载（诊断/测试用） */
    func isMmapBacked(): Bool
}