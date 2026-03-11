package badgercj.db

import std.sync.*
import std.collection.*
import badgercj.table.*

public struct WriteEntry {
    public let key: Array<Byte>
    public let value: Array<Byte>
    public let isDelete: Bool
    public var vp: ?ValuePointer
    
    public init(key: Array<Byte>, value: Array<Byte>, isDelete!: Bool = false) {
        this.key = key
        this.value = value
        this.isDelete = isDelete
        this.vp = None
    }
}

public class WriteRequest {
    public let commitTs: UInt64
    private let entries: ArrayList<WriteEntry>
    private let counter: SyncCounter
    
    public init(commitTs: UInt64) {
        this.commitTs = commitTs
        this.entries = ArrayList<WriteEntry>()
        this.counter = SyncCounter(1)
    }
    
    public init(key: Array<Byte>, value: Array<Byte>, commitTs: UInt64, isDelete!: Bool = false) {
        this.commitTs = commitTs
        this.entries = ArrayList<WriteEntry>()
        this.entries.add(WriteEntry(key, value, isDelete: isDelete))
        this.counter = SyncCounter(1)
    }
    
    public func addEntry(key: Array<Byte>, value: Array<Byte>, isDelete!: Bool = false): Unit {
        entries.add(WriteEntry(key, value, isDelete: isDelete))
    }
    
    public func getEntries(): ArrayList<WriteEntry> {
        entries
    }
    
    public func entryCount(): Int64 {
        entries.size
    }
    
    public func wait(): Unit {
        counter.waitUntilZero()
    }
    
    public func done(): Unit {
        counter.dec()
    }
}