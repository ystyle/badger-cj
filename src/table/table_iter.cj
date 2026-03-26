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
}