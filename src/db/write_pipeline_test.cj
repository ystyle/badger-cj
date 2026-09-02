package badgercj.db

import std.collection.*

// v1.6.10 回归：写管道错误语义（仓颉规范 §异常处理）
// - 业务写失败（Exception）→ markFailed 携带真实消息，commit() 返回 TxnStatus.Error(具体信息)
// - 系统级 Error（OOM 等）→ 不在业务层捕获（runBatch 无 catch Error 分支），
//   finally 保证 done() 后自然传播（仓颉不允许手动 throw Error，该路径由语言语义保证）
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
}
