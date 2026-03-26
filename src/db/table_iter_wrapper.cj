package badgercj.db

import badgercj.table.*

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
    
    public override func seek(key: Array<Byte>): Unit {
        iter.seek(key)
    }
}