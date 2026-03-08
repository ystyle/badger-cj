package badgercj.db

import badgercj.table.*
import std.collection.*

public class MockTable {
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
    
    public func get(key: Array<Byte>, readTs: UInt64): Option<ValueStruct> {
        for (entry in entries) {
            if (keysEqual(entry[0], key)) {
                return Some(entry[1])
            }
        }
        return None
    }
    
    private func keysEqual(a: Array<Byte>, b: Array<Byte>): Bool {
        if (a.size != b.size) {
            return false
        }
        var i: Int64 = 0
        while (i < a.size) {
            if (a[i] != b[i]) {
                return false
            }
            i++
        }
        return true
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
}
