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
    private let mutex: Mutex
    private var cond: ?Condition
    private let done: AtomicBool
    
    public init(key: Array<Byte>, value: Array<Byte>, commitTs: UInt64, isDelete!: Bool = false) {
        this.key = key
        this.value = value
        this.commitTs = commitTs
        this.isDelete = isDelete
        this.vp = None
        this.mutex = Mutex()
        this.cond = None
        this.done = AtomicBool(false)
    }
    
    private func getCondition(): Condition {
        if (cond.isNone()) {
            mutex.lock()
            try {
                if (cond.isNone()) {
                    cond = Some(mutex.condition())
                }
            } finally {
                mutex.unlock()
            }
        }
        return cond.getOrThrow()
    }
    
    public func wait(): Unit {
        mutex.lock()
        try {
            while (!done.load()) {
                getCondition().wait()
            }
        } finally {
            mutex.unlock()
        }
    }
    
    public func signal(): Unit {
        mutex.lock()
        try {
            done.store(true)
            if (cond.isSome()) {
                cond.getOrThrow().notifyAll()
            }
        } finally {
            mutex.unlock()
        }
    }
}
