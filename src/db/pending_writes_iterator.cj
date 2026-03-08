package badgercj.db

import std.collection.ArrayList
import badgercj.table.ValueStruct
import badgercj.table.Meta

/**
 * PendingWritesIterator - 事务未提交写入的迭代器
 * 
 * 遍历 Transaction 的 pending writes
 */
public class PendingWritesIterator <: SimpleIterator {
    private let entries: ArrayList<(Array<Byte>, Array<Byte>)>
    private var currentIndex: Int64
    private var currentKey: Array<Byte>
    private var currentValue: Array<Byte>
    private var valid_: Bool
    private let reverse: Bool
    
    public init(writes: ArrayList<TxnEntry>, reverse!: Bool = false) {
        super()
        this.entries = ArrayList<(Array<Byte>, Array<Byte>)>()
        this.reverse = reverse
        this.currentIndex = -1
        this.currentKey = []
        this.currentValue = []
        this.valid_ = false
        
        // 将 TxnEntry 转换为编码的 ValueStruct
        for (entry in writes) {
            let meta: Byte = if (entry.isDelete()) {
                Meta.bitDelete
            } else {
                0
            }
            let vs = ValueStruct(entry.value, meta: meta)
            entries.add((entry.key, vs.encode()))
        }
        
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
        if (entries.isEmpty()) {
            valid_ = false
            return
        }
        
        if (reverse) {
            currentIndex = Int64(entries.size) - 1
        } else {
            currentIndex = 0
        }
        updateCurrent()
    }
    
    public override func seek(key: Array<Byte>): Unit {
        if (entries.isEmpty()) {
            valid_ = false
            return
        }
        
        if (reverse) {
            var found: Int64 = -1
            for (i in 0..entries.size) {
                if (compareKeys(entries[i][0], key) >= 0) {
                    found = i
                }
            }
            if (found >= 0) {
                currentIndex = found
                updateCurrent()
            } else {
                valid_ = false
            }
        } else {
            var lo: Int64 = 0
            var hi: Int64 = entries.size - 1
            var found: Int64 = -1
            
            while (lo <= hi) {
                let mid = (lo + hi) / 2
                let cmp = compareKeys(entries[mid][0], key)
                if (cmp < 0) {
                    lo = mid + 1
                } else {
                    found = mid
                    hi = mid - 1
                }
            }
            
            if (found >= 0) {
                currentIndex = found
                updateCurrent()
            } else {
                valid_ = false
            }
        }
    }
    
    private func updateCurrent(): Unit {
        if (currentIndex >= 0 && currentIndex < entries.size) {
            let entry = entries[currentIndex]
            currentKey = entry[0]
            currentValue = entry[1]
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
