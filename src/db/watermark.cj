package badgercj.db

import std.sync.*
import std.collection.*

protected class WaterMark {
    private let name: String
    private let doneUntil_: AtomicUInt64
    private let lastIndex_: AtomicUInt64
    private let lock: Mutex
    // 同一 ts 可能被多个活跃事务共享（并发读事务 readTs 相同），因此用计数而非集合：
    // 用 Set 时「读事务 A begin(1) → 写事务 begin(1) → 写事务 done(1)」会把 A 的登记
    // 一并移除，doneUntil 提前推进 → compaction 会丢掉仍被 A 需要的版本。
    private let pending: HashMap<UInt64, Int64>
    private let running: AtomicBool
    
    public init(name: String) {
        this.name = name
        this.doneUntil_ = AtomicUInt64(0)
        this.lastIndex_ = AtomicUInt64(0)
        this.lock = Mutex()
        this.pending = HashMap<UInt64, Int64>()
        this.running = AtomicBool(true)
    }
    
    public func begin(index: UInt64): Unit {
        lock.lock()
        addPending(index)
        if (index > lastIndex_.load()) {
            lastIndex_.store(index)
        }
        lock.unlock()
    }
    
    private func addPending(index: UInt64): Unit {
        let cur: Int64 = if (pending.contains(index)) { pending[index] } else { 0 }
        pending[index] = cur + 1
    }
    
    private func removePending(index: UInt64): Unit {
        if (!pending.contains(index)) {
            return
        }
        let cur = pending[index]
        if (cur <= 1) {
            pending.remove(index)
        } else {
            pending[index] = cur - 1
        }
    }
    
    public func beginMany(indices: Array<UInt64>): Unit {
        lock.lock()
        var maxIdx: UInt64 = 0
        for (idx in indices) {
            addPending(idx)
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
        removePending(index)
        updateDoneUntil()
        lock.unlock()
    }
    
    public func doneMany(indices: Array<UInt64>): Unit {
        lock.lock()
        for (idx in indices) {
            removePending(idx)
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