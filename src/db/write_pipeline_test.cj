package badgercj.db

import std.collection.*
import std.sync.*
import std.time.*

// v1.6.10 回归：写管道错误语义（仓颉规范 §异常处理）
// - 业务写失败（Exception）→ markFailed 携带真实消息，commit() 返回 TxnStatus.Error(具体信息)
// - 系统级 Error（OOM 等）→ 不在业务层捕获（runBatch 无 catch Error 分支），
//   finally 保证 done() 后自然传播（仓颉不允许手动 throw Error，该路径由语言语义保证）
// v1.6.13 补充：runBatch 的 Error 逃逸到 loop() 必须被边界兜底捕获——否则管道协程死亡，
//   后续所有写请求 done() 永不回调 = 调用方永久挂起（生产忆时塔 MCP 挂起症状）。
// v1.6.16 补充（评审 P2）：Error 不再只靠 loop() 边界兜底——runBatch 内 catch Error
//   并整批 markFailed（先于 finally done()），失败对调用方显式可见（errorOf Some），
//   杜绝 OOM 批 commit() 误报成功 = 静默丢写。
// v1.6.20 补充：**失败文案不允许为空**。OOM 等系统级 Error 的 message 常为空串，
//   原样透传 → 调用方只看到 Exception("")，生产排查被迫从"空消息"反推 OOM（忆时塔两次
//   事故都是这个签名）。systemFailureMsg/failureMsg 在 message 为空时退回 toString()
//   并标注「系统级错误」，本用例断言文案非空且含该标注。
@Test
class WritePipelineErrorSemanticsTest {

    // 业务异常路径：markFailed 携带真实消息 + wait() 不悬挂
    @TestCase
    func testBusinessExceptionMarksFailedWithMessage() {
        let reqs = ArrayList<WriteRequest>()
        reqs.add(WriteRequest(1))
        let pipe = WritePipeline({ _ => throw Exception("arena overflow") })
        pipe.emit(reqs)
        reqs[0].wait()   // finally 中 done() → wait 正常返回，不悬挂
        match (reqs[0].errorOf()) {
            case Some(msg) => @Expect(msg == "arena overflow")
            case None => @Expect(false)   // 必须标记失败，不能静默成功
        }
        pipe.close()
    }

    // 正常路径：无异常时 errorOf() 为 None（不被误标失败）
    @TestCase
    func testNoExceptionNoFailureMark() {
        let reqs = ArrayList<WriteRequest>()
        reqs.add(WriteRequest(1))
        let pipe = WritePipeline({ _ => () })
        pipe.emit(reqs)
        reqs[0].wait()
        @Expect(reqs[0].errorOf().isNone())
        pipe.close()
    }

    // 系统级 Error（真实 OOM）逃逸 runBatch 后：管道协程必须存活，
    // 后续批次仍被处理（loop() 边界 catch Error，只记录不退出）
    @TestCase
    func testSystemErrorDoesNotKillPipeline() {
        let okReqs = ArrayList<WriteRequest>()
        okReqs.add(WriteRequest(1))
        okReqs.add(WriteRequest(2))
        // 真实 OutOfMemoryError（Error 层级，无法手动 throw Error）：
        // 分配超巨型数组并 touch 首字节强制运行时提交。sink 让数组逃逸出闭包，
        // 防止 -O2 死代码消除（仅读 size 或读取结果未消费时整个分配被优化掉、
        // OOM 永不触发——v1.6.13 原测试即因此从未真正抛过 Error，属假阳性）。
        let sink = ArrayList<Array<Byte>>()
        let oomOnce = AtomicInt64(0)
        let pipe = WritePipeline({ reqs =>
            if (oomOnce.fetchAdd(1) == 0) {
                // 仅首次批次触发 OOM；后续批次走正常路径验证管道存活
                let huge = Array<Byte>(Int64.Max - 1024, repeat: 0)
                sink.add(huge)
                let _ = huge[0]
            }
            for (r in reqs) { r.done() }
        })
        pipe.emit(okReqs)   // 本批必然 OOM

        // 等待 OOM 批 settle（runBatch finally 已 done，wait 不悬挂）
        okReqs[0].wait()
        okReqs[1].wait()

        // v1.6.16（评审 P2）：OOM 批必须显式标记失败（errorOf Some）——
        // 此前 Error 只被 loop() 边界捕获打印，本批 done() 未带失败标记，
        // commit() wait 后 errorOf()==None 返回 Ok = 静默丢写（write_request.cj
        // "杜绝写入失败却返回成功" 目标仅覆盖 Exception，Error 漏网）。
        // markFailed 必须在 finally done() 之前完成，否则 wait 已返回、补标无效。
        @Expect(okReqs[0].errorOf().isSome())
        @Expect(okReqs[1].errorOf().isSome())

        // 失败文案必须可诊断：OOM 的 message 常为空，原样透传会让调用方只看到
        // Exception("")（生产事故现场：维护任务每轮 "Job 0 failed:（空）"+ 写路径全断）。
        // 必须带出 Error 类型，且标明是系统级错误。
        match (okReqs[0].errorOf()) {
            case Some(msg) =>
                @Expect(msg != "", true)
                @Expect(msg.contains("系统级错误"), true)
            case None => @Expect(false)
        }

        // OOM 后管道必须仍存活：再发一批正常请求，必须被处理（wait 返回、无失败标记）
        let nextReqs = ArrayList<WriteRequest>()
        nextReqs.add(WriteRequest(3))
        pipe.emit(nextReqs)
        nextReqs[0].wait()
        @Expect(nextReqs[0].errorOf().isNone())
        pipe.close()
    }
}
