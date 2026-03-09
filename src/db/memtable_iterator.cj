package badgercj.db

import std.collection.ArrayList
import badgercj.table.ValueStruct

public class MemTableIterator <: SimpleIterator {
    private let entries: ArrayList<(Array<Byte>, Array<Byte>)>
    private let reverse: Bool
    private var index: Int64
    private var currentKey: Array<Byte>
    private var currentValue: Array<Byte>
    private var valid_: Bool
    
    public init(mt: MemTable, reverse!: Bool = false) {
        super()
        this.entries = ArrayList<(Array<Byte>, Array<Byte>)>()
        this.reverse = reverse
        this.index = -1
        this.currentKey = []
        this.currentValue = []
        this.valid_ = false
        
        let skipIter = mt.iterator()
        while (skipIter.hasNext()) {
            if (let Some((key, vs)) <- skipIter.next()) {
                // 存储完整的编码 ValueStruct（包含 meta、version 等）
                entries.add((key, vs.encode()))
            }
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
        advance()
    }
    
    public override func rewind(): Unit {
        if (entries.isEmpty()) {
            valid_ = false
            return
        }
        
        if (reverse) {
            index = Int64(entries.size) - 1
        } else {
            index = 0
        }
        updateCurrent()
    }
    
    public override func seek(key: Array<Byte>): Unit {
        if (entries.isEmpty()) {
            valid_ = false
            return
        }
        
        // 对于按 ~ts 降序排列的 key，seek 需要找最后一个 >= seekKey 的 entry
        // 因为时间戳被取反，高版本排在前面，所以需要从后向前找
        var lo: Int64 = 0
        var hi: Int64 = entries.size - 1
        var found: Int64 = -1
        
        while (lo <= hi) {
            let mid = (lo + hi) / 2
            let cmp = compareKeys(entries[mid][0], key)
            if (cmp <= 0) {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        
        if (found >= 0) {
            index = found
            updateCurrent()
        } else {
            valid_ = false
        }
    }
    
    private func advance(): Unit {
        if (reverse) {
            index--
            if (index < 0) {
                valid_ = false
                return
            }
        } else {
            index++
            if (index >= entries.size) {
                valid_ = false
                return
            }
        }
        updateCurrent()
    }
    
    private func updateCurrent(): Unit {
        if (index >= 0 && index < entries.size) {
            let entry = entries[index]
            currentKey = entry[0]
            currentValue = entry[1]
            valid_ = true
        } else {
            valid_ = false
        }
    }
    
    private func compareKeys(a: Array<Byte>, b: Array<Byte>): Int64 {
        let minLen = if (a.size < b.size) { a.size } else { b.size }
        for (i in 0..minLen) {
            if (a[i] < b[i]) {
                return -1
            }
            if (a[i] > b[i]) {
                return 1
            }
        }
        if (a.size < b.size) {
            return -1
        }
        if (a.size > b.size) {
            return 1
        }
        return 0
    }
}
