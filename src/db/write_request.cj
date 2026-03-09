package badgercj.db

import std.sync.*
import std.time.*
import badgercj.table.*

public class WriteRequest {
    public let key: Array<Byte>
    public let value: Array<Byte>
    public let commitTs: UInt64
    public let isDelete: Bool
    public var vp: ?ValuePointer
    private let done: AtomicBool
    
    public init(key: Array<Byte>, value: Array<Byte>, commitTs: UInt64, isDelete!: Bool = false) {
        this.key = key
        this.value = value
        this.commitTs = commitTs
        this.isDelete = isDelete
        this.vp = None
        this.done = AtomicBool(false)
    }
    
    public func wait(): Unit {
        var retries = 0
        let maxRetries = 1000000
        while (!done.load() && retries < maxRetries) {
            sleep(Duration.nanosecond * 100)
            retries++
        }
        if (!done.load()) {
            throw Exception("WriteRequest.wait() timeout after 100ms")
        }
    }
    
    public func signal(): Unit {
        done.store(true)
    }
}
