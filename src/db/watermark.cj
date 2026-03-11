package badgercj.db

import std.sync.*
import std.collection.*

public class WaterMark {
    private let name: String
    private let doneUntil_: AtomicUInt64
    private let lastIndex_: AtomicUInt64
    private let lock: Mutex
    private let pending: HashSet<UInt64>
    private let running: AtomicBool
    
    public init(name: String) {
        this.name = name
        this.doneUntil_ = AtomicUInt64(0)
        this.lastIndex_ = AtomicUInt64(0)
        this.lock = Mutex()
        this.pending = HashSet<UInt64>()
        this.running = AtomicBool(true)
    }
    
    public func begin(index: UInt64): Unit {
        lock.lock()
        pending.add(index)
        if (index > lastIndex_.load()) {
            lastIndex_.store(index)
        }
        lock.unlock()
    }
    
    public func beginMany(indices: Array<UInt64>): Unit {
        lock.lock()
        var maxIdx: UInt64 = 0
        for (idx in indices) {
            pending.add(idx)
            if (idx > maxIdx) {
                maxIdx = idx
            }
        }
        if (maxIdx > lastIndex_.load()) {
            lastIndex_.store(maxIdx)
        }
        lock.unlock()
    }
    
    public func done(index: UInt64): Unit {
        lock.lock()
        pending.remove(index)
        updateDoneUntil()
        lock.unlock()
    }
    
    public func doneMany(indices: Array<UInt64>): Unit {
        lock.lock()
        for (idx in indices) {
            pending.remove(idx)
        }
        updateDoneUntil()
        lock.unlock()
    }
    
    public func doneUntil(): UInt64 {
        return doneUntil_.load()
    }
    
    public func setDoneUntil(val: UInt64): Unit {
        doneUntil_.store(val)
    }
    
    public func lastIndex(): UInt64 {
        return lastIndex_.load()
    }
    
    public func stop(): Unit {
        running.store(false)
    }
    
    private func updateDoneUntil(): Unit {
        var next = doneUntil_.load() + 1
        while (!pending.contains(next) && next <= lastIndex_.load()) {
            doneUntil_.store(next)
            next++
        }
    }
}