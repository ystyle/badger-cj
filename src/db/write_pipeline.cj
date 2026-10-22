package badgercj.db

import std.sync.*
import std.collection.*
import std.collection.concurrent.*
import std.time.*

// 失败文案：系统级 Error（OOM 等）的 message 常常是**空串**——原样透传会让调用方只看到
// `Exception("")`，生产现场表现为「维护任务每轮 Job 0 failed:（空消息）」+ 写路径全断而
// 毫无线索（忆时塔两次生产事故都栽在这条空消息上，见 docs/blog/2026-09-09-cangjie-service-oom-hunt.md
// 「空 message 异常 ≈ OOM」）。message 为空时退回 toString()（含异常类型名）。
func failureMsg(e: Exception): String {
    if (e.message != "") { e.message } else { e.toString() }
}

// 系统级 Error 版本：额外标注「系统级错误」，让 OOM 在一眼之下就能被认出来
// （仓颉 Error 与 Exception 是两条继承链，诊断时必须区分开）
func systemFailureMsg(e: Error): String {
    if (e.message != "") { e.message } else { "系统级错误（OOM 等）：" + e.toString() }
}

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
                // 兜底防线（v1.6.13 起）：runBatch 已内部捕获 Error 整批 markFailed，
                // 此处再兜底队列层异常（如 remove 系统级错误）——系统级错误（OOM 等）
                // 不许逃逸杀写管道协程：记录后继续循环，否则一次资源耗尽 = 管道死亡 =
                // 后续所有写请求 done() 永不回调 = 调用方永久挂起（生产 MCP 挂起症状）。
                println("[badger] write pipeline loop system error: " + systemFailureMsg(e))
            }
        }
        
        while (queue.size() > 0) {
            try {
                if (let Some(reqs) <- queue.tryRemove()) {
                    runBatch(reqs)
                }
            } catch (e: Error) {
                println("[badger] write pipeline drain system error: " + systemFailureMsg(e))
            }
        }
    }
    
    // 执行一批写请求（对齐 badger-go writeRequests 的 done(err) 语义）：
    // handler 抛异常（如 arena 溢出、value 超过 64KB 编码上限）时给本批每个 req
    // 标记失败——commit() 就此返回 TxnStatus.Error，而不是"假装成功"的静默丢数据。
    // handler 抛系统级 Error（如 OOM）：同样整批 markFailed 后再 done()——Error 虽
    // 无法在业务层重新抛出（仓颉不允许手动 throw Error），但失败必须对调用方可见，
    // 否则本批只 done() 不标记 → commit() wait 返回后 errorOf()==None → 误报成功 =
    // 静默丢写（评审 P2；此前该场景仅由 loop() 边界捕获打印，批次对外显示成功）。
    // markFailed 必须先于 finally 的 done()：wait() 唤醒后再补标已无意义。
    // done() 的唯一所有权在本函数：handler **不得**自行 done()（否则每个请求被 done
    // 两次）。重复 done 会把已被 WriteRequestPool 复用并 reset() 的请求计数器减到 0，
    // 让下一批 commit 在写入完成前被提前唤醒（写后读不到 / 请求被并发 reset 清空）。
    // 附带语义：失败部分条目可能已写入（失败≠零写入，badger-go 相同）。
    private func runBatch(reqs: ArrayList<WriteRequest>): Unit {
        try {
            handler(reqs)
        } catch (e: Exception) {
            for (req in reqs) {
                req.markFailed(failureMsg(e))
            }
        } catch (e: Error) {
            // 系统级错误（如 OOM）：整批标记失败（错误信息透出给调用方），
            // finally 仍保证 done()，管道协程不死亡（与 loop 边界兜底一致）。
            // OOM 的 message 常为空 → systemFailureMsg 兜底成带类型的文案，
            // 否则调用方只看到 Exception("")（生产事故的「空消息」签名）。
            for (req in reqs) {
                req.markFailed(systemFailureMsg(e))
            }
        } finally {
            for (req in reqs) {
                req.done()
            }
        }
    }
}
