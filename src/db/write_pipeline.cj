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
            try {
                if (let Some(reqs) <- queue.remove()) {
                    runBatch(reqs)
                }
            } catch (e: Error) {
                // 系统级错误（如 OOM 的 OutOfMemoryError）不许逃逸杀写管道协程：
                // 记录后继续循环，否则一次资源耗尽 = 管道死亡 = 后续所有写请求
                // done() 永不回调 = 调用方永久挂起（生产忆时塔 MCP 挂起症状）。
                println("[badger] write pipeline loop system error: " + e.message)
            }
        }
        
        while (queue.size() > 0) {
            try {
                if (let Some(reqs) <- queue.tryRemove()) {
                    runBatch(reqs)
                }
            } catch (e: Error) {
                println("[badger] write pipeline drain system error: " + e.message)
            }
        }
    }
    
    // 执行一批写请求（对齐 badger-go writeRequests 的 done(err) 语义）：
    // handler 抛异常（如 arena 溢出、value 超过 64KB 编码上限）时给本批每个 req
    // 标记失败——commit() 就此返回 TxnStatus.Error，而不是"假装成功"的静默丢数据。
    // done() 放 finally：即使抛的是 Error（如内存耗尽，不在 Exception 体系内）也保证
    // 调用方 wait() 不悬挂（评审 P2-3）；Error 不在此捕获——按仓颉语义属系统级错误，
    // 执行完 finally 后自然传播（打印堆栈 + 终止进程），而非被业务层吞掉。
    // 附带语义：失败部分条目可能已写入（失败≠零写入，badger-go 相同）。
    private func runBatch(reqs: ArrayList<WriteRequest>): Unit {
        try {
            handler(reqs)
        } catch (e: Exception) {
            for (req in reqs) {
                req.markFailed(e.message)
            }
        } finally {
            for (req in reqs) {
                req.done()
            }
        }
    }
}
