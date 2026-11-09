package badgercj.table

import std.collection.*

/**
 * TableIter - 公开的表迭代器接口
 * 
 * 支持正向和反向迭代
 */
public interface TableIter {
    func seekFirst(): Unit
    func seekLast(): Unit
    func seek(key: Array<Byte>): Unit
    func next(): Unit
    func prev(): Unit
    func isValid(): Bool
    func key(): Array<Byte>
    func value(): Array<Byte>
    func valueStruct(): ?ValueStruct
    /**
     * 关闭迭代器：归还它持有的表引用（最后一个引用释放时才解映射/删表文件）。
     * 幂等；关闭后不应继续读写。**所有创建路径都必须关闭**，否则该表永不释放。
     */
    func close(): Unit
}