package badgercj.db

import std.sync.*
import std.collection.*

public class WriteRequestPool {
    private let pool = ArrayList<WriteRequest>()
    private let mutex = Mutex()
    private let maxSize: Int64
    
    public init(maxSize!: Int64 = 1000) {
        this.maxSize = maxSize
    }
    
    public func get(commitTs: UInt64): WriteRequest {
        synchronized(mutex) {
            if (pool.size > 0) {
                let req = pool.remove(at: 0)
                req.reset(commitTs)
                return req
            }
        }
        return WriteRequest(commitTs)
    }
    
    public func put(req: WriteRequest): Unit {
        synchronized(mutex) {
            if (pool.size < maxSize) {
                pool.add(req)
            }
        }
    }
}