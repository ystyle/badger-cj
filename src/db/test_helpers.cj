package badgercj.db

import std.fs.*
import std.io.*

public func bytesToString(bytes: Array<Byte>): String {
    String.fromUtf8(bytes)
}

public func cleanupDir(path: String): Unit {
    if (exists(Path(path))) {
        remove(Path(path), recursive: true)
    }
}

// —— 数据文件检查辅助（持久化 / 崩溃恢复测试用）——
//
// 用途：持久化验证分两层——
//   ① 读层：close → reopen → get 命中（数据语义完整）；
//   ② 数据文件层：目录里真实存在 .sst / MANIFEST / WAL，且数量与生命周期符合预期
//      （落盘时机、WAL 清理、空库不产文件等），防止"只在内存里自洽、从未真正落盘"
//      的假持久化（issue: flush-no-persist-oom-mcp-hang 教训）。
// 命名带 test 前缀，避免与业务代码顶层函数冲突。

// 统计目录内指定后缀（".sst"/".mem"/".vlog"）的文件数；目录不存在返回 0
public func testCountFilesWithSuffix(dir: String, suffix: String): Int64 {
    if (!exists(Path(dir))) {
        return 0
    }
    var count: Int64 = 0
    for (entry in Directory.readFrom(Path(dir))) {
        if (entry.name.endsWith(suffix)) {
            count++
        }
    }
    count
}

// 文件字节数；不存在返回 0
public func testFileBytesSize(path: String): Int64 {
    if (!exists(Path(path))) {
        return 0
    }
    let f = File(path, Read)
    let len = f.length
    f.close()
    len
}

// 目录文件快照 "name=size,..."（诊断打印用）
public func testDirFileSnapshot(dir: String): String {
    if (!exists(Path(dir))) {
        return "[]"
    }
    var result = "["
    var first = true
    for (entry in Directory.readFrom(Path(dir))) {
        let p = Path(dir + "/" + entry.name)
        var size: Int64 = 0
        if (exists(p)) {
            let f = File(p, Read)
            size = f.length
            f.close()
        }
        if (!first) {
            result += ","
        }
        result += "${entry.name}=${size}"
        first = false
    }
    result += "]"
    result
}
