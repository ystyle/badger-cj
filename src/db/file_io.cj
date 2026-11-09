package badgercj.db

import std.fs.*
import badgercj.io_uring.*

/**
 * 文件写入工具
 * 
 * 支持 io_uring 异步写入（Linux）和同步写入（其他平台）
 */

/**
 * writeFile - 写入数据到文件
 * 
 * 如果 useIoUring=true 且平台支持，使用 io_uring 异步写入
 * 否则使用同步写入
 * 
 * 参数：
 * - path: 文件路径
 * - data: 要写入的数据
 * - useIoUring: 是否尝试使用 io_uring
 * 
 * 返回：实际写入的字节数
 */
protected func writeFile(path: String, data: Array<Byte>, useIoUring!: Bool = true): Int64 {
    if (useIoUring) {
        if (let Some(writer) <- createIoUringWriter(path)) {
            writer.write(data)
            writer.sync()
            writer.close()
            return Int64(data.size)
        }
    }
    
    let f = File(Path(path), Write)
    f.write(data)
    f.close()
    return Int64(data.size)
}

/**
 * syncWriteFile - 同步写入数据到文件
 * 
 * 强制使用同步写入，不尝试 io_uring
 */
protected func syncWriteFile(path: String, data: Array<Byte>): Int64 {
    let f = File(Path(path), Write)
    f.write(data)
    f.close()
    return Int64(data.size)
}
/**
 * 表文件分段写器（2.1 L2 流式落盘用）：block 完成即写，io_uring 可用时按队列分段提交，
 * 不可用/写失败回退普通 File 写（与 writeFile 的降级语义一致）。
 */
protected class TableFileSink {
    private var writer: ?IoUringInterface
    private var file: ?File
    private var written: Int64

    public init(path: String, useIoUring!: Bool = true) {
        this.written = 0
        if (useIoUring) {
            if (let Some(w) <- createIoUringWriter(path)) {
                this.writer = Some(w)
                this.file = None
                return
            }
        }
        // 回退：普通 File 写（先清空已有内容）
        if (exists(Path(path))) {
            remove(Path(path))
        }
        this.file = Some(File(Path(path), Write))
        this.writer = None
    }

    public func write(data: Array<Byte>): Unit {
        match (writer) {
            case Some(w) => w.write(data)
            case None =>
                match (file) {
                    case Some(f) => f.write(data)
                    case None => throw Exception("TableFileSink not initialized")
                }
        }
        written += Int64(data.size)
    }

    public func finish(): Int64 {
        match (writer) {
            case Some(w) =>
                w.sync()
                w.close()
            case None =>
                match (file) {
                    case Some(f) => f.close()
                    case None => ()
                }
        }
        written
    }
}
