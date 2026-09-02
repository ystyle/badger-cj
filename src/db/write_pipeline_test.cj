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
        let pipe = WritePipeline({ reqs =>
            // 触发真实 OutOfMemoryError（Error 层级，无法手动 throw）
            let huge = Array<Byte>(Int64.Max - 1024, repeat: 0)
            for (r in reqs) { let _ = huge.size; r.done() }
        })
        pipe.emit(okReqs)   // 本批必然 OOM

        // 等待 OOM 批 settle（runBatch finally 已 done，wait 不悬挂）
        okReqs[0].wait()
        okReqs[1].wait()

        // OOM 后管道必须仍存活：再发一批正常请求，必须被处理（wait 返回、无失败标记）
        let nextReqs = ArrayList<WriteRequest>()
        nextReqs.add(WriteRequest(3))
        pipe.emit(nextReqs)
        nextReqs[0].wait()
        @Expect(nextReqs[0].errorOf().isNone())
        pipe.close()
    }
}
