package badgercj.db

import badgercj.table.*
import badgercj.utils.compareKeys

public class TableIterWrapper <: SimpleIterator {
    private let iter: TableIter
    private let reverse: Bool
    
    public init(iter: TableIter, reverse!: Bool = false) {
        super()
        this.iter = iter
        this.reverse = reverse
        rewind()
    }
    
    public override func valid(): Bool { iter.isValid() }
    public override func key(): Array<Byte> { iter.key() }
    public override func value(): Array<Byte> {
        if (let Some(vs) <- iter.valueStruct()) {
            return vs.encode()
        }
        return []
    }
    
    public override func next(): Unit {
        if (reverse) { iter.prev() } else { iter.next() }
    }
    
    public override func rewind(): Unit {
        if (reverse) { iter.seekLast() } else { iter.seekFirst() }
    }
    
    // 归还底层 TableIter 持有的表引用
    public override func close(): Unit {
        iter.close()
    }
    
    public override func seek(key: Array<Byte>): Unit {
        if (reverse) {
            // reverse seek 语义（对齐 MemTableIterator.reverse.seek）：
            // 定位到 ≤ key 的最后一条（含相等），从该处向前迭代。
            // 直接透传前向 seek（≥ key 第一条）会错位：seek key 大于表内全部 key 时
            // 前向定位 invalid → reverse 迭代空结果；落在两 key 之间时起点偏大。
            iter.seek(key)
            if (!iter.isValid()) {
                // key 大于表内全部 key：reverse 应从表尾（最大 key）开始
                iter.seekLast()
            } else if (compareKeys(iter.key(), key) > 0) {
                // 前向定位到的第一条 > key（无相等）：回退一步到 ≤ key 的最后一条
                iter.prev()
            }
        } else {
            iter.seek(key)
        }
    }
}