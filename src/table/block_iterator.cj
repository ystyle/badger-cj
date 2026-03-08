package badgercj.table

/**
 * BlockIterator - Block 迭代器
 * 
 * 遍历 Block 中的所有 entry
 */
public class BlockIterator {
    private let data: Array<Byte>
    private var offset: Int64
    private var entryOffsets: Array<UInt32>
    private var numEntries: UInt32
    private var currentIdx: Int64
    private var baseKey: Array<Byte>
    private var currentKey: Array<Byte>
    private var currentValue: Array<Byte>
    private var valid: Bool
    
    public init(data: Array<Byte>, baseKey: Array<Byte>) {
        this.data = data
        this.offset = 0
        this.baseKey = baseKey
        this.currentKey = []
        this.currentValue = []
        this.valid = false
        this.currentIdx = -1
        
        let numEntriesOffset = Int64(data.size) - 4 - 8
        this.numEntries = UInt32(data[numEntriesOffset]) |
                          (UInt32(data[numEntriesOffset + 1]) << 8) |
                          (UInt32(data[numEntriesOffset + 2]) << 16) |
                          (UInt32(data[numEntriesOffset + 3]) << 24)
        
        this.entryOffsets = Array<UInt32>(Int64(numEntries), {i =>
            let entryOffset = numEntriesOffset - 4 - (i + 1) * 4
            UInt32(data[entryOffset]) |
            (UInt32(data[entryOffset + 1]) << 8) |
            (UInt32(data[entryOffset + 2]) << 16) |
            (UInt32(data[entryOffset + 3]) << 24)
        })
    }
    
    /**
     * 移动到第一个 entry
     */
    public func seekToFirst(): Unit {
        currentIdx = 0
        if (numEntries > 0) {
            parseEntry()
        } else {
            valid = false
        }
    }
    
    /**
     * 查找指定 key
     */
    public func seek(key: Array<Byte>): Unit {
        var left: Int64 = 0
        var right: Int64 = Int64(numEntries) - 1
        
        while (left <= right) {
            let mid = (left + right) / 2
            seekTo(Int64(mid))
            
            let cmp = compareKeys(key, currentKey)
            if (cmp == 0) {
                return
            } else if (cmp < 0) {
                right = mid - 1
            } else {
                left = mid + 1
            }
        }
        
        valid = false
    }
    
    /**
     * 移动到下一个 entry
     */
    public func next(): Unit {
        currentIdx++
        if (currentIdx < Int64(numEntries)) {
            parseEntry()
        } else {
            valid = false
        }
    }
    
    /**
     * 移动到指定索引
     */
    private func seekTo(idx: Int64): Unit {
        currentIdx = idx
        parseEntry()
    }
    
    /**
     * 解析当前 entry
     */
    private func parseEntry(): Unit {
        if (currentIdx < 0 || currentIdx >= Int64(numEntries)) {
            valid = false
            return
        }
        
        offset = Int64(entryOffsets[currentIdx])
        
        let overlap = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        offset += 2
        
        let diffLen = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        offset += 2
        
        let diffKey = data[offset..(offset + Int64(diffLen))]
        offset += Int64(diffLen)
        
        if (Int64(overlap) > baseKey.size) {
            valid = false
            return
        }
        
        currentKey = Array<Byte>(Int64(overlap) + Int64(diffLen), {i =>
            if (i < Int64(overlap)) {
                baseKey[i]
            } else {
                diffKey[i - Int64(overlap)]
            }
        })
        
        currentValue = parseValue()
        valid = true
    }
    
    /**
     * 解析 Value
     */
    private func parseValue(): Array<Byte> {
        let startOffset = offset
        
        let meta = data[offset]
        offset++
        
        let userMeta = data[offset]
        offset++
        
        var expiresAt: UInt64 = 0
        if ((meta & 0x20) != 0) {
            expiresAt = UInt64(data[offset]) |
                       (UInt64(data[offset + 1]) << 8) |
                       (UInt64(data[offset + 2]) << 16) |
                       (UInt64(data[offset + 3]) << 24) |
                       (UInt64(data[offset + 4]) << 32) |
                       (UInt64(data[offset + 5]) << 40) |
                       (UInt64(data[offset + 6]) << 48) |
                       (UInt64(data[offset + 7]) << 56)
            offset += 8
        }
        
        var valueLen: UInt64 = 0
        var shift: UInt64 = 0
        while (true) {
            let b = UInt64(data[offset])
            offset++
            valueLen |= (b & 0x7F) << shift
            if ((b & 0x80) == 0) {
                break
            }
            shift += 7
        }
        
        return data[offset..(offset + Int64(valueLen))]
    }
    
    private func compareKeys(a: Array<Byte>, b: Array<Byte>): Int64 {
        let minLen = if (a.size < b.size) { a.size } else { b.size }
        
        for (i in 0..minLen) {
            if (a[i] < b[i]) {
                return -1
            } else if (a[i] > b[i]) {
                return 1
            }
        }
        
        if (a.size < b.size) {
            return -1
        } else if (a.size > b.size) {
            return 1
        }
        
        return 0
    }
    
    /**
     * 是否有效
     */
    public func isValid(): Bool {
        return valid
    }
    
    /**
     * 获取当前 key
     */
    public func key(): Array<Byte> {
        return currentKey
    }
    
    /**
     * 获取当前 value
     */
    public func value(): Array<Byte> {
        return currentValue
    }
}
