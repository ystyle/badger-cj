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