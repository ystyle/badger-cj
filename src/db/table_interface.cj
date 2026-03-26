package badgercj.db

import std.collection.*
import badgercj.table.*

public interface TableInterface {
    func getId(): UInt64
    func smallest(): Array<Byte>
    func biggest(): Array<Byte>
    func get(key: Array<Byte>, readTs: UInt64): Option<ValueStruct>
    func size(): Int64
    func getMaxVersion(): UInt64
    func keyCount(): UInt32
    func uncompressedSize(): Int64
    func offsetsLength(): Int64
    func getOffsetKey(idx: Int64): Array<Byte>
    func keySplits(n: Int64, prefix: Array<Byte>): ArrayList<Array<Byte>>
}