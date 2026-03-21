package badgercj.db

import std.sync.*
import std.collection.*

protected class NotifyingWriteChannel<T> {
    private let queue = ArrayList<T>()
    private let mutex = Mutex()
    private let cond: Condition
    private let capacity: Int64
    private var closed = AtomicBool(false)
    
    public init(capacity: Int64) {
        this.capacity = capacity
        synchronized(mutex) {
            this.cond = mutex.condition()
        }
    }
    
    public func add(item: T): Unit {
        synchronized(mutex) {
            queue.add(item)
            cond.notify()
        }
    }
    
    public func remove(): ?T {
        synchronized(mutex) {
            while (queue.isEmpty() && !closed.load()) {
                cond.wait()
            }
            if (queue.isEmpty()) {
                return None
            }
            let item = queue.remove(at: 0)
            return Some(item)
        }
    }
    
    public func tryRemove(): ?T {
        synchronized(mutex) {
            if (queue.isEmpty()) {
                return None
            }
            let item = queue.remove(at: 0)
            return Some(item)
        }
    }
    
    public func size(): Int64 {
        synchronized(mutex) {
            queue.size
        }
    }
    
    public func close(): Unit {
        synchronized(mutex) {
            closed.store(true)
            cond.notifyAll()
        }
    }
    
    public func isClosed(): Bool {
        closed.load()
    }
}