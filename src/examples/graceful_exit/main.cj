package badgercj.examples.graceful_exit

import std.env.*
import std.fs.*
import std.time.*
import std.collection.*
import badgercj.db.*

// docker stop 优雅退出端到端验证程序：
//   graceful_exit write <dir>          —— open + 单事务写入 5000 条（不 close、不显式 flush，
//                                         数据只存在内存 memtable/imm + WAL buffer，即"未落盘"）
//                                         + registerSignalShutdown()（收到 SIGTERM → close → exit(0)）
//   graceful_exit write-nosignal <dir> —— 对照组：不注册优雅退出，SIGTERM 默认终止（模拟未适配场景）
//   graceful_exit read <dir>           —— 重启后 open + 读回统计 + close
//
// bash 驱动（scripts/graceful_shutdown_e2e.sh）：
//   graceful_exit write $DIR > log 2>&1 &  PID=$!
//   轮询 $DIR/ready.flag → kill -TERM $PID → wait $PID（应为 0）
//   graceful_exit read $DIR → 期望 FOUND: 5000/5000
main(args: Array<String>): Int64 {
    if (args.size < 2) {
        println("usage: graceful_exit write|write-nosignal|read <dir>")
        return 2
    }
    let mode = args[0]
    let dir = args[1]
    match (mode) {
        case "write" => writePhase(dir, true)
        case "write-nosignal" => writePhase(dir, false)
        case "read" => readPhase(dir)
        case _ =>
            println("unknown mode: ${mode}")
            return 2
    }
    return 0
}

let TOTAL: Int64 = 5000

func writePhase(dir: String, registerSignal: Bool): Unit {
    // 小 memtable：5000 条必然触发多轮运行中 flush（数据进 imm 内存表，仍未写盘）
    let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))
    let txn = db.newTransaction(update: true)
    for (i in 0..TOTAL) {
        txn.set(("key-" + i.toString()).toArray(), ("value-" + i.toString()).toArray())
    }
    let status = txn.commit()
    if (status.isOk()) {
        println("WRITTEN ${TOTAL}")
    } else {
        println("WRITE FAILED")
        return
    }
    println("READY")
    // stdout 可能是全缓冲（重定向到文件），主动 flush 供脚本轮询日志
    getStdOut().flush()
    // 就绪标记文件（脚本最稳的轮询信号）
    writeReadyFlag(dir)
    if (registerSignal) {
        // 注册优雅退出（默认 exitAfterClose=true）：SIGTERM/SIGINT → close → exit(0)。
        // 不显式 close——模拟 docker stop 直接发信号。
        db.registerSignalShutdown()
    } else {
        // 对照组：不注册——SIGTERM 走默认终止（无优雅退出，数据仅靠 WAL buffer）
        println("NO-SIGNAL-HANDLER")
        getStdOut().flush()
    }
    // 阻塞等待信号；优雅退出模式下 shutdownLoop 收到后执行 close + exit(0)
    while (true) {
        sleep(Duration.second)
    }
}

func readPhase(dir: String): Unit {
    let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))
    // 诊断：L0 表加载情况
    let lvl = db.levels()
    let totalTables = db.tables().size
    println("DIAG tables=${totalTables}, levels=${lvl.size}")
    let txn = db.newTransaction(update: false)
    var found: Int64 = 0
    var mismatch: Int64 = 0
    for (i in 0..TOTAL) {
        let key = ("key-" + i.toString()).toArray()
        let expect = ("value-" + i.toString()).toArray()
        let got = txn.get(key)
        if (let Some(v) <- got) {
            if (v == expect) {
                found += 1
            } else {
                mismatch += 1
            }
        }
    }
    txn.discard()
    println("FOUND: ${found}/${TOTAL}, mismatch: ${mismatch}")
    db.close()
}

func writeReadyFlag(dir: String): Unit {
    let flagPath = dir + "/ready.flag"
    let f = File(Path(flagPath), ReadWrite)
    f.write("ready".toArray())
    f.close()
}
