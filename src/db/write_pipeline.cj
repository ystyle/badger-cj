package badgercj.db

import std.sync.*
import std.collection.*
import std.collection.concurrent.*
import std.time.*

public class WritePipeline {
    private let queue: CloseableBlockingQueue<ArrayList<WriteRequest>>
    private let running: AtomicBool
    private var fut: ?Future<Unit>
    private let handler: (ArrayList<WriteRequest>) -> Unit
    
    public init(handler: (ArrayList<WriteRequest>) -> Unit, queueSize!: Int64 = 1000) {
        this.queue = CloseableBlockingQueue<ArrayList<WriteRequest>>(queueSize)
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
                runBatch(reqs)
            }
        }
        
        while (queue.size() > 0) {
            if (let Some(reqs) <- queue.tryRemove()) {
                runBatch(reqs)
            }
        }
    }
    
    // 执行一批写请求（对齐 badger-go writeRequests 的 done(err) 语义）：
    // handler 抛异常（如 arena 溢出、value 超过 64KB 编码上限）时给本批每个 req
    // 标记失败——commit() 就此返回 TxnStatus.Error，而不是"假装成功"的静默丢数据。
    // done() 放 finally：即使抛的是 Error（如内存耗尽，不在 Exception 体系内）也保证
    // 调用方 wait() 不悬挂（评审 P2-3）。
    // 附带语义：失败部分条目可能已写入（失败≠零写入，badger-go 相同）。
    private func runBatch(reqs: ArrayList<WriteRequest>): Unit {
        try {
            handler(reqs)
        } catch (e: Exception) {
            for (req in reqs) {
                req.markFailed(e.message)
            }
        } catch (e: Error) {
            for (req in reqs) {
                req.markFailed("runtime error while writing batch")
            }
        } finally {
            for (req in reqs) {
                req.done()
            }
        }
    }
}