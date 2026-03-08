package badgercj.db

import std.collection.*

/**
 * PendingWritesIterator - 事务未提交写入的迭代器
 * 
 * 遍历 Transaction 的 pending writes
 */
public class PendingWritesIterator <: SimpleIterator {
    private let writes: ArrayList<TxnEntry>
    private var currentIndex: Int64
    private var currentKey: Array<Byte>
    private var currentValue: Array<Byte>
    private var valid_: Bool
    private let reverse: Bool
    
    public init(writes: ArrayList<TxnEntry>, reverse!: Bool = false) {
        super()
        this.writes = writes
        this.reverse = reverse
        this.currentIndex = -1
        this.currentKey = []
        this.currentValue = []
        this.valid_ = false
        
        rewind()
    }
    
    public override func valid(): Bool {
        return valid_
    }
    
    public override func key(): Array<Byte> {
        return currentKey
    }
    
    public override func value(): Array<Byte> {
        return currentValue
    }
    
    public override func next(): Unit {
        if (reverse) {
            currentIndex--
        } else {
            currentIndex++
        }
        updateCurrent()
    }
    
    public override func rewind(): Unit {
        if (reverse) {
            currentIndex = writes.size - 1
        } else {
            currentIndex = 0
        }
        updateCurrent()
    }
    
    public override func seek(key: Array<Byte>): Unit {
        currentIndex = 0
        for (i in 0..writes.size) {
            if (compareKeys(writes[i].key, key) >= 0) {
                currentIndex = i
                break
            }
        }
        updateCurrent()
    }
    
    private func updateCurrent(): Unit {
        if (currentIndex >= 0 && currentIndex < writes.size) {
            let entry = writes[currentIndex]
            currentKey = entry.key
            currentValue = entry.value
            valid_ = true
        } else {
            currentKey = []
            currentValue = []
            valid_ = false
        }
    }
    
    private func compareKeys(a: Array<Byte>, b: Array<Byte>): Int64 {
        let minLen = if (a.size < b.size) { a.size } else { b.size }
        for (i in 0..minLen) {
            if (a[i] != b[i]) {
                return Int64(a[i]) - Int64(b[i])
            }
        }
        return Int64(a.size) - Int64(b.size)
    }
}