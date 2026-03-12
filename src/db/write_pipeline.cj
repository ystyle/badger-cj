package badgercj.db

import std.sync.*
import std.collection.*
import std.collection.concurrent.*
import std.time.*

public class WritePipeline {
    private let queue: NotifyingWriteChannel<ArrayList<WriteRequest>>
    private let running: AtomicBool
    private var fut: ?Future<Unit>
    private let handler: (ArrayList<WriteRequest>) -> Unit
    
    public init(handler: (ArrayList<WriteRequest>) -> Unit, queueSize!: Int64 = 1000) {
        this.queue = NotifyingWriteChannel<ArrayList<WriteRequest>>(queueSize)
        this.handler = handler
        this.running = AtomicBool(true)
        this.fut = None
        this.fut = spawn { this.loop() }
    }
    
    public func emit(reqs: ArrayList<WriteRequest>): Unit {
        queue.add(reqs)
    }
    
    public func close(): Unit {
        running.store(false)
        queue.close()
        if (let Some(f) <- fut) {
            f.get()
        }
    }
    
    private func loop(): Unit {
        while (running.load()) {
            if (let Some(reqs) <- queue.remove()) {
                try {
                    handler(reqs)
                } catch (e: Exception) {
                    for (req in reqs) {
                        req.done()
                    }
                }
            }
        }
        
        while (queue.size() > 0) {
            if (let Some(reqs) <- queue.tryRemove()) {
                handler(reqs)
            }
        }
    }
}