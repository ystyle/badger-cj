package badgercj.db

import badgercj.table.*
import std.collection.*
import badgercj.utils.{keysEqual, hasPrefix}

public class MockTable <: TableInterface {
    public let id: UInt64
    public let smallestKey: Array<Byte>
    public let biggestKey: Array<Byte>
    private let entries: ArrayList<(Array<Byte>, ValueStruct)>
    
    public init(id: UInt64, entries: ArrayList<(Array<Byte>, ValueStruct)>) {
        this.id = id
        this.entries = ArrayList<(Array<Byte>, ValueStruct)>()
        
        if (entries.size == 0) {
            this.smallestKey = []
            this.biggestKey = []
            return
        }
        
        for (entry in entries) {
            this.entries.add(entry)
        }
        
        let firstEntry = this.entries[0]
        let lastEntry = this.entries[this.entries.size - 1]
        this.smallestKey = firstEntry[0]
        this.biggestKey = lastEntry[0]
    }
    
    public func getId(): UInt64 {
        return id
    }
    
    public func get(key: Array<Byte>, readTs: UInt64): Option<ValueStruct> {
        for (entry in entries) {
            if (keysEqual(entry[0], key)) {
                return Some(entry[1])
            }
        }
        return None
    }
    
    public func smallest(): Array<Byte> { smallestKey }
    public func biggest(): Array<Byte> { biggestKey }
    public func size(): Int64 { 
        var s: Int64 = 0
        for (entry in entries) {
            s += Int64(entry[0].size) + entry[1].estimateSize()
        }
        return s
    }
    
    public func getEntries(): ArrayList<(Array<Byte>, ValueStruct)> {
        return entries
    }
    
    public func getMaxVersion(): UInt64 {
        var maxVer: UInt64 = 0
        for (entry in entries) {
            if (entry[1].version > maxVer) {
                maxVer = entry[1].version
            }
        }
        return maxVer
    }
    
    public func keyCount(): UInt32 {
        UInt32(entries.size)
    }
    
    public func uncompressedSize(): Int64 {
        size()
    }
    
    public func offsetsLength(): Int64 {
        entries.size
    }
    
    public func getOffsetKey(idx: Int64): Array<Byte> {
        if (idx < 0 || idx >= entries.size) {
            return []
        }
        entries[idx][0]
    }
    
    public func keySplits(n: Int64, prefix: Array<Byte>): ArrayList<Array<Byte>> {
        let result = ArrayList<Array<Byte>>()
        if (n <= 0) {
            return result
        }
        
        let jump = entries.size / n
        var actualJump = if (jump == 0) { 1 } else { jump }
        
        var i: Int64 = 0
        while (i < entries.size) {
            let key = entries[i][0]
            if (hasPrefix(key, prefix)) {
                result.add(key)
            }
            i += actualJump
        }
        
        result
    }
}
