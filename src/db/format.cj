package badgercj.db

import std.fs.*
import std.collection.*
import std.convert.*

/**
 * 数据目录格式声明（`<dir>/FORMAT`）。
 *
 * 为什么要有它：v1.6.x/v2.0 的字节语法相同（SSTable/MANIFEST/LogEntry 布局不变），
 * 差异只在「文件布局与物理大小」（WAL 多段、VLog 稀疏预分配）。没有版本载体时，
 * 将来引入改字节语义的能力（如加密、merge operator 标记）就无法区分「旧库」与「新库」，
 * 只能靠启发式猜。故 2.0.0 起在建库/首次打开时写出基线：
 *
 *   format=1
 *   features=
 *
 * 约定：
 * - 文件缺失 = v1.6.x 的 format=1（天然兼容旧目录），首次打开后补写；
 * - format 高于本版本支持上限 → 拒绝打开（防止旧二进制误读新格式）；
 * - features 里出现本版本不认识的项 → 拒绝打开（防止降级读错语义）；
 * - 不把版本塞进 MANIFEST：ManifestChangeSet 的解码器遇未知顶层 tag 不推进 offset，
 *   旧版本读到新 MANIFEST 会死循环。
 */
protected class FormatInfo {
    public let format: Int64
    public let features: ArrayList<String>

    public init(format: Int64, features: ArrayList<String>) {
        this.format = format
        this.features = features
    }
}

/** 本版本可写/可读的格式号。2.0.0 = 1（与 v1.6.x 同字节语法）。 */
protected let CurrentFormat: Int64 = 1

protected func formatPath(dir: String): String {
    "${dir}/FORMAT"
}

/** 读取并校验 FORMAT。缺失 = format 1、无 feature。 */
protected func readFormat(dir: String): FormatInfo {
    let p = Path(formatPath(dir))
    if (!exists(p)) {
        return FormatInfo(CurrentFormat, ArrayList<String>())
    }
    let bytes = File.readFrom(p)
    var format: Int64 = -1
    let features = ArrayList<String>()
    var i: Int64 = 0
    while (i < bytes.size) {
        // 行首空白
        while (i < bytes.size && (bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0D)) {
            i++
        }
        if (i >= bytes.size) {
            break
        }
        if (bytes[i] == 0x0A) {
            i++
            continue
        }
        if (bytes[i] == 0x23) { // '#' 注释
            while (i < bytes.size && bytes[i] != 0x0A) {
                i++
            }
            continue
        }
        let keyStart = i
        while (i < bytes.size && bytes[i] != 0x3D && bytes[i] != 0x0A) {
            i++
        }
        let key = String.fromUtf8(bytes[keyStart..i])
        if (i >= bytes.size || bytes[i] != 0x3D) {
            throw BadgerException.corruptionError("Invalid FORMAT file: missing '=' (key '${key}')")
        }
        i++ // '='
        let valStart = i
        while (i < bytes.size && bytes[i] != 0x0A) {
            i++
        }
        var valEnd = i
        while (valEnd > valStart && (bytes[valEnd - 1] == 0x20 || bytes[valEnd - 1] == 0x09 ||
            bytes[valEnd - 1] == 0x0D)) {
            valEnd--
        }
        let value = String.fromUtf8(bytes[valStart..valEnd])
        match (key) {
            case "format" =>
                match (Int64.tryParse(value)) {
                    case Some(n) => format = n
                    case None => throw BadgerException.corruptionError("Invalid FORMAT value '${value}'")
                }
            case "features" => parseFormatFeatures(value, features)
            case _ => throw BadgerException.corruptionError("Unknown FORMAT key '${key}'")
        }
    }
    if (format < 0) {
        throw BadgerException.corruptionError("FORMAT file missing 'format='")
    }
    FormatInfo(format, features)
}

private func parseFormatFeatures(value: String, out: ArrayList<String>): Unit {
    let bytes = value.toArray()
    var start: Int64 = 0
    var i: Int64 = 0
    while (i <= bytes.size) {
        if (i == bytes.size || bytes[i] == 0x2C) {
            if (i > start) {
                out.add(String.fromUtf8(bytes[start..i]))
            }
            start = i + 1
        }
        i++
    }
}

/**
 * 打开目录时校验格式基线；缺失则补写当前格式。
 * 高于支持版本 / 未知 feature → 抛 invalidConfig（拒绝打开，不猜测）。
 */
protected func ensureFormat(dir: String): Unit {
    let info = readFormat(dir)
    if (info.format > CurrentFormat) {
        throw BadgerException.invalidConfig(
            "Unsupported data format ${info.format} (this build supports up to ${CurrentFormat}); refusing to open ${dir}")
    }
    for (f in info.features) {
        throw BadgerException.invalidConfig("Unknown data feature '${f}'; refusing to open ${dir}")
    }
    if (!exists(Path(formatPath(dir)))) {
        writeFormat(dir)
    }
}

private func writeFormat(dir: String): Unit {
    let content = "format=${CurrentFormat}\nfeatures=\n"
    let f = File(Path(formatPath(dir)), OpenMode.Write)
    try {
        f.write(content.toArray())
        f.flush()
    } finally {
        f.close()
    }
}
