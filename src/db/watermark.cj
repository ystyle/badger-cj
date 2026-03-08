package badgercj.db

import std.sync.*
import std.collection.*
import std.collection.concurrent.*

struct Mark {
    public let index: UInt64
    public let indices: Array<UInt64>
    public let isDone: Bool
    
    public init(index: UInt64, isDone: Bool) {
        this.index = index
        this.indices = []
        this.isDone = isDone
    }
    
    public init(indices: Array<UInt64>, isDone: Bool) {
        this.index = 0
        this.indices = indices
        this.isDone = isDone
    }
}

public class WaterMark {
    private let name: String
    private let doneUntil_: AtomicUInt64
    private let lastIndex_: AtomicUInt64
    private let markQueue: LinkedBlockingQueue<Mark>
    private let running: AtomicBool
    private let lock: Mutex
    
    public init(name: String) {
        this.name = name
        this.doneUntil_ = AtomicUInt64(0)
        this.lastIndex_ = AtomicUInt64(0)
        this.markQueue = LinkedBlockingQueue<Mark>(1000)
        this.running = AtomicBool(true)
        this.lock = Mutex()
        
        spawn {
            this.process()
        }
    }
    
    public func begin(index: UInt64): Unit {
        lastIndex_.store(index)
        markQueue.add(Mark(index, false))
    }
    
    public func beginMany(indices: Array<UInt64>): Unit {
        if (indices.size > 0) {
            lastIndex_.store(indices[indices.size - 1])
        }
        markQueue.add(Mark(indices, false))
    }
    
    public func done(index: UInt64): Unit {
        markQueue.add(Mark(index, true))
    }
    
    public func doneMany(indices: Array<UInt64>): Unit {
        markQueue.add(Mark(indices, true))
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
    
    private func process(): Unit {
        let indices = MinHeap()
        let pending = HashMap<UInt64, Int32>()
        
        while (running.load()) {
            let markOpt = markQueue.remove(Duration.millisecond * 100)
            if (markOpt.isNone()) {
                continue
            }
            
            let mark = markOpt ?? throw Exception("No mark")
            processMark(mark, indices, pending)
        }
    }
    
    private func processMark(
        mark: Mark,
        indices: MinHeap,
        pending: HashMap<UInt64, Int32>
    ): Unit {
        if (mark.index > 0 || (mark.index == 0 && mark.indices.size == 0)) {
            processOne(mark.index, mark.isDone, indices, pending)
        }
        
        for (index in mark.indices) {
            processOne(index, mark.isDone, indices, pending)
        }
    }
    
    private func processOne(
        index: UInt64,
        done: Bool,
        indices: MinHeap,
        pending: HashMap<UInt64, Int32>
    ): Unit {
        let prevOpt = pending.get(index)
        let prev: Int32 = if (let Some(v) <- prevOpt) { v } else { 0 }
        
        if (prevOpt.isNone()) {
            indices.push(index)
        }
        
        let delta: Int32 = if (done) { -1 } else { 1 }
        pending[index] = prev + delta
        
        let currentDoneUntil = doneUntil_.load()
        var until = currentDoneUntil
        
        while (!indices.isEmpty()) {
            let minOpt = indices.peek()
            if (minOpt.isNone()) {
                break
            }
            let min = minOpt ?? throw Exception("No min")
            let pendingCountOpt = pending.get(min)
            let pendingCount: Int32 = if (let Some(v) <- pendingCountOpt) { v } else { 0 }
            
            if (pendingCount > 0) {
                break
            }
            
            indices.pop()
            pending.remove(min)
            until = min
        }
        
        if (until != currentDoneUntil) {
            doneUntil_.store(until)
        }
    }
}

class MinHeap {
    private var data: ArrayList<UInt64>
    
    public init() {
        this.data = ArrayList<UInt64>()
    }
    
    public func push(val: UInt64): Unit {
        data.add(val)
        siftUp(data.size - 1)
    }
    
    public func pop(): Unit {
        if (data.size == 0) {
            return
        }
        
        data[0] = data[data.size - 1]
        data.remove(at: data.size - 1)
        
        if (data.size > 0) {
            siftDown(0)
        }
    }
    
    public func peek(): Option<UInt64> {
        if (data.size == 0) {
            return None
        }
        return Some(data[0])
    }
    
    public func isEmpty(): Bool {
        return data.size == 0
    }
    
    private func siftUp(idx: Int64): Unit {
        var i = idx
        while (i > 0) {
            let parent = (i - 1) / 2
            if (data[parent] <= data[i]) {
                break
            }
            let temp = data[parent]
            data[parent] = data[i]
            data[i] = temp
            i = parent
        }
    }
    
    private func siftDown(idx: Int64): Unit {
        var i = idx
        let half = data.size / 2
        
        while (i < half) {
            var child = 2 * i + 1
            let left = child
            let right = child + 1
            
            if (right < data.size && data[right] < data[left]) {
                child = right
            } else {
                child = left
            }
            
            if (data[i] <= data[child]) {
                break
            }
            
            let temp = data[i]
            data[i] = data[child]
            data[child] = temp
            i = child
        }
    }
}
