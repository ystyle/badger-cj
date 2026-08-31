package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*
import std.sync.*
import std.time.*
import std.env.getProcessId
import std.posix.kill

// 优雅退出回归（docker stop / Ctrl+C）：
// registerSignalShutdown() 注册后，SIGTERM 触发后台线程 close()。
// 仅 Linux 测试（std.runtime 信号 API 不支持 Windows）。
@When[os == "Linux"]
@Test
class GracefulShutdownTest {

    private static let DIR = "/tmp/badger_graceful_shutdown_test"

    private func cleanup(): Unit {
        let path = Path(DIR)
        if (exists(path)) {
            remove(path, recursive: true)
        }
    }

    @TestCase
    func testSigtermTriggersGracefulClose(): Unit {
        cleanup()
        let db = Badger.open(Config(dir: DIR, memTableSize: 64 * 1024u64))
        // 写入一条数据，确保关闭前有可 flush 的内容
        let ok = db.update({ t => t.set("k".toArray(), "v".toArray()) })
        @Assert(ok.isSuccess(), true)

        // 注册优雅退出；exitAfterClose=false：close 后不退出进程，便于断言
        db.registerSignalShutdown(exitAfterClose: false)

        // 稍后发送 SIGTERM（15），模拟 docker stop
        spawn {
            sleep(Duration.millisecond * 200)
            let _ = kill(Int32(getProcessId()), 15)
        }

        // 轮询等待 db 关闭：close 后 writeCh.add 抛异常（update 的 commit 在 try 外，
        // 异常会向上传播），捕获到即视为已关闭
        var closed = false
        var attempts = 0
        while (attempts < 200 && !closed) {
            try {
                let r = db.update({ t => t.set("after".toArray(), "sig".toArray()) })
                if (r.isError()) {
                    closed = true
                }
            } catch (e: Exception) {
                closed = true
            }
            if (!closed) {
                sleep(Duration.millisecond * 50)
                attempts += 1
            }
        }
        @Assert(closed, true)
        cleanup()
    }

    @TestCase
    func testRegisterTwiceIsIdempotent(): Unit {
        cleanup()
        let db = Badger.open(Config(dir: DIR, memTableSize: 64 * 1024u64))
        db.registerSignalShutdown(exitAfterClose: false)
        db.registerSignalShutdown(exitAfterClose: false)
        // 二次注册不重复 spawn 后台线程；close 后信号 handler 已注销，update 返回 Error
        spawn {
            sleep(Duration.millisecond * 200)
            let _ = kill(Int32(getProcessId()), 15)
        }
        var closed = false
        var attempts = 0
        while (attempts < 200 && !closed) {
            try {
                let r = db.update({ t => t.set("after".toArray(), "sig".toArray()) })
                if (r.isError()) {
                    closed = true
                }
            } catch (e: Exception) {
                closed = true
            }
            if (!closed) {
                sleep(Duration.millisecond * 50)
                attempts += 1
            }
        }
        @Assert(closed, true)
        cleanup()
    }

    // 优雅关闭钩子：SIGTERM 优雅关闭时，close() 之前按注册顺序执行（方案 B——宿主把
    // 清理逻辑注册进 badger，无信号注册顺序依赖）。
    @TestCase
    func testShutdownHookExecutedOnSigterm(): Unit {
        cleanup()
        let db = Badger.open(Config(dir: DIR, memTableSize: 64 * 1024u64))
        let hookRan = AtomicBool(false)
        db.registerShutdownHook({ => hookRan.store(true) })
        db.registerSignalShutdown(exitAfterClose: false)

        spawn {
            sleep(Duration.millisecond * 200)
            let _ = kill(Int32(getProcessId()), 15)
        }
        var closed = false
        var attempts = 0
        while (attempts < 200 && !closed) {
            try {
                let r = db.update({ t => t.set("after".toArray(), "sig".toArray()) })
                if (r.isError()) {
                    closed = true
                }
            } catch (e: Exception) {
                closed = true
            }
            if (!closed) {
                sleep(Duration.millisecond * 50)
                attempts += 1
            }
        }
        @Assert(closed, true)
        @Assert(hookRan.load(), true)
        cleanup()
    }

    // 钩子按注册顺序执行：钩子1 store(1) → 钩子2 store(2)，最终值为 2 说明顺序正确
    // （若乱序，钩子2 先执行再被钩子1 覆盖，最终为 1）。
    @TestCase
    func testShutdownHooksRunInOrder(): Unit {
        cleanup()
        let db = Badger.open(Config(dir: DIR, memTableSize: 64 * 1024u64))
        let lastRun = AtomicInt64(0)
        db.registerShutdownHook({ => lastRun.store(1) })
        db.registerShutdownHook({ => lastRun.store(2) })
        db.registerSignalShutdown(exitAfterClose: false)

        spawn {
            sleep(Duration.millisecond * 200)
            let _ = kill(Int32(getProcessId()), 15)
        }
        var closed = false
        var attempts = 0
        while (attempts < 200 && !closed) {
            try {
                let r = db.update({ t => t.set("after".toArray(), "sig".toArray()) })
                if (r.isError()) {
                    closed = true
                }
            } catch (e: Exception) {
                closed = true
            }
            if (!closed) {
                sleep(Duration.millisecond * 50)
                attempts += 1
            }
        }
        @Assert(closed, true)
        @Assert(lastRun.load() == 2, true)
        cleanup()
    }
}
