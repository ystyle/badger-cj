package badgercj.table

import badgercj.utils.compareKeys

/**
 * BlockIterator - Block 迭代器
 * 
 * 遍历 Block 中的所有 entry
 */
protected class BlockIterator {
    private let data: Array<Byte>
    private var offset: Int64
    private var entryOffsets: Array<UInt32>
    private var numEntries: UInt32
    private var currentIdx: Int64
    private var baseKey: Array<Byte>
    private var currentKey: Array<Byte>
    private var currentValue: ?ValueStruct
    private var valid: Bool
    
    public init(data: Array<Byte>, baseKey: Array<Byte>) {
        this.data = data
        this.offset = 0
        this.baseKey = baseKey
        this.currentKey = []
        this.currentValue = None
        this.valid = false
        this.currentIdx = -1
        this.entryOffsets = []
        this.numEntries = 0
        
        if (data.size < 12) {
            return
        }
        
        let numEntriesOffset = Int64(data.size) - 12
        this.numEntries = UInt32(data[numEntriesOffset]) |
                          (UInt32(data[numEntriesOffset + 1]) << 8) |
                          (UInt32(data[numEntriesOffset + 2]) << 16) |
                          (UInt32(data[numEntriesOffset + 3]) << 24)
        
        let entryOffsetsStart = numEntriesOffset - Int64(numEntries) * 4
        if (entryOffsetsStart < 0) {
            this.numEntries = 0
            return
        }
        
        this.entryOffsets = Array<UInt32>(Int64(numEntries), {i =>
            let pos = entryOffsetsStart + Int64(i) * 4
            UInt32(data[pos]) |
            (UInt32(data[pos + 1]) << 8) |
            (UInt32(data[pos + 2]) << 16) |
            (UInt32(data[pos + 3]) << 24)
        })
    }
    
    public func seekToFirst(): Unit {
        currentIdx = 0
        if (numEntries > 0) {
            parseEntry()
        } else {
            valid = false
        }
    }
    
    public func seek(key: Array<Byte>): Unit {
        var left: Int64 = 0
        var right: Int64 = Int64(numEntries) - 1
        var foundIdx: Int64 = -1
        
        while (left <= right) {
            let mid = (left + right) / 2
            seekTo(Int64(mid))
            
            let cmp = compareKeys(key, currentKey)
            if (cmp == 0) {
                return
            } else if (cmp < 0) {
                right = mid - 1
                foundIdx = mid
            } else {
                left = mid + 1
            }
        }
        
        if (foundIdx >= 0) {
            seekTo(foundIdx)
        } else if (left < Int64(numEntries)) {
            seekTo(left)
        } else {
            valid = false
        }
    }
    
    public func next(): Unit {
        currentIdx++
        if (currentIdx < Int64(numEntries)) {
            parseEntry()
        } else {
            valid = false
        }
    }
    
    public func prev(): Unit {
        currentIdx--
        if (currentIdx >= 0) {
            parseEntry()
        } else {
            valid = false
        }
    }
    
    public func seekToLast(): Unit {
        currentIdx = Int64(numEntries) - 1
        if (currentIdx >= 0) {
            parseEntry()
        } else {
            valid = false
        }
    }
    
    private func seekTo(idx: Int64): Unit {
        currentIdx = idx
        parseEntry()
    }
    
    private func parseEntry(): Unit {
        if (currentIdx < 0 || currentIdx >= Int64(numEntries)) {
            valid = false
            return
        }
        
        offset = Int64(entryOffsets[currentIdx])
        
        if (offset < 0 || offset + 4 > data.size) {
            valid = false
            return
        }
        
        let overlap = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        offset += 2
        
        let diffLen = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        offset += 2
        
        if (offset + Int64(diffLen) > data.size) {
            valid = false
            return
        }
        
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
        
        currentValue = parseValueStruct()
        valid = true
    }
    
    private func parseValueStruct(): ?ValueStruct {
        if (offset >= data.size) {
            return None
        }
        
        let meta = data[offset]
        offset++
        
        let userMeta = data[offset]
        offset++
        
        var version: UInt64 = 0
        var shift: UInt64 = 0
        while (offset < data.size) {
            let b = UInt64(data[offset])
            offset++
            version |= (b & 0x7F) << shift
            if ((b & 0x80) == 0) {
                break
            }
            shift += 7
        }
        
        var expiresAt: UInt64 = 0
        if ((meta & 0x10) != 0 && offset + 8 <= data.size) {
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
        shift = 0
        while (offset < data.size) {
            let b = UInt64(data[offset])
            offset++
            valueLen |= (b & 0x7F) << shift
            if ((b & 0x80) == 0) {
                break
            }
            shift += 7
        }
        
        if (offset + Int64(valueLen) > data.size) {
            return None
        }
        let value = data[offset..(offset + Int64(valueLen))]
        return Some(ValueStruct(value, meta: meta, userMeta: userMeta, version: version, expiresAt: expiresAt))
    }
    
    public func isValid(): Bool {
        return valid
    }
    
    public func key(): Array<Byte> {
        return currentKey
    }
    
    public func value(): Array<Byte> {
        if (let Some(vs) <- currentValue) {
            return vs.value
        }
        return []
    }
    
    public func valueStruct(): ?ValueStruct {
        currentValue
    }
}
