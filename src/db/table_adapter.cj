package badgercj.db

import std.collection.*
import badgercj.table.*

public class TableAdapter <: TableInterface {
    private let table: Table
    
    protected init(table: Table) {
        this.table = table
    }
    
    public func getId(): UInt64 {
        return table.id
    }
    
    public func smallest(): Array<Byte> {
        table.smallest
    }
    
    public func biggest(): Array<Byte> {
        table.biggest
    }
    
    public func get(key: Array<Byte>, readTs: UInt64): Option<ValueStruct> {
        let seekKey = keyWithTs(key, readTs)
        
        // 走表级迭代器（TableIterator.next 块尾自动进下一块）：同 user key 多版本
        // 跨多个 block 时单块扫描会漏掉更旧的可读版本；同时依赖 findBlock 的
        // 同 user key 组定位修复（R3）保证 seek 落到正确起始块。
        let iter = table.newIterator()
        iter.seek(seekKey)
        
        while (iter.isValid()) {
            let iterKey = iter.key()
            if (sameKey(iterKey, key)) {
                let ts = parseTs(iterKey)
                if (ts <= readTs) {
                    if (let Some(vs) <- iter.valueStruct()) {
                        return Some(vs)
                    }
                }
            } else {
                // 已进入下一个 user key（组结束），无 ≤ readTs 的可读版本
                break
            }
            iter.next()
        }
        
        return None
    }
    
    public func size(): Int64 {
        Int64(table.keyCount)
    }
    
    public func getMaxVersion(): UInt64 {
        table.maxVersion
    }
    
    public func keyCount(): UInt32 {
        table.keyCount
    }
    
    public func uncompressedSize(): Int64 {
        table.uncompressedSize()
    }
    
    public func offsetsLength(): Int64 {
        table.offsetsLength()
    }
    
    public func getOffsetKey(idx: Int64): Array<Byte> {
        table.getOffsetKey(idx)
    }
    
    public func keySplits(n: Int64, prefix: Array<Byte>): ArrayList<Array<Byte>> {
        table.keySplits(n, prefix)
    }
    
    protected func getTable(): Table {
        table
    }
    
    public func newIterator(): TableIter {
        table.newIterator()
    }
}