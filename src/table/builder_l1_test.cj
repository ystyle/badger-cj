package badgercj.table

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import ystyle::crc.*

// TableBuilder L1（单拷贝）改造回归（docs/plans/2026-09-05-async-flusher-l1-builder-design.md）：
//   - golden 指纹等价：改造前由旧实现生成的代表性表指纹（size + 字节和 + 位置加权和 +
//     平方和）固化于此，改造后输出必须一致——文件格式位级不变契约的直接证明；
//   - 尾部布局与 checksum 自洽（写入值 == 同输入重算值，覆盖 blocks+index+indexSize，
//     两侧同实现，L1 前后一致即布局/覆盖范围未变）；
//   - 空表 finish 返回空数组（行为修正：不再落盘空表）。
//
// 注：实测 -O2 下 ystyle::crc 的 CRC32C 对 builder 产物（toArray 大数组）行为不稳定
// （同一数据跨编译不同值、单字节翻转不敏感），指纹因此用纯算术折叠实现（任意单
// 字节差异必然改变指纹）；CRC32C 优化疑点另案记录（checksum 字段读侧不校验，无
// 功能影响，待 crc-cj 修复后启用真校验）。
@Test
class TableBuilderL1Test {
    // —— golden 指纹（旧实现生成，见 testPrintGoldenForL1，格式 "size|sum|wsum|sq"）——
    private static let GOLDEN_UNCOMPRESSED: String = "30357|3255380|405598346|528074526"
    private static let GOLDEN_SNAPPY: String = "10999|611063|76127446|117870765"
    private static let GOLDEN_BIGVALUE: String = "102516|13059263|1632287067|2224261291"
    private static let GOLDEN_MULTIVER: String = "11116|371003|46854961|57062713"

    // 有序 key 构造：SSTable 要求 key 严格升序（前缀压缩 + 二分查找依赖）。
    // 前 keyLen-8 字节固定前缀 + 尾 8 字节大端 i。
    private static func orderedKey(i: Int64, keyLen: Int64): Array<Byte> {
        let key = Array<Byte>(keyLen, repeat: 0u8)
        for (j in 0..(keyLen - 8)) {
            key[j] = 0x6Bu8
        }
        var v = UInt64(i)
        var k = keyLen - 1
        while (k >= keyLen - 8) {
            key[k] = UInt8(v & 0xFF)
            v = v >> 8
            k--
        }
        key
    }
    
    // 确定性指纹："size|Σb|Σ(b·w_i)|Σ(b²)"，w_i = (i+1) % 251（单项 ≤ 255×250，
    // 百 KB 级总和不溢出 Int64）
    private static func fingerprint(data: Array<Byte>): String {
        var sumB: Int64 = 0
        var wsum: Int64 = 0
        var sq: Int64 = 0
        var i: Int64 = 0
        while (i < data.size) {
            let b = Int64(data[i])
            sumB += b
            wsum += b * ((i + 1) % 251)
            sq += b * b
            i++
        }
        "${data.size}|${sumB}|${wsum}|${sq}"
    }
    
    // 尾部布局与 checksum 自洽（结构锚）
    private static func assertTailContract(data: Array<Byte>): Unit {
        if (data.size == 0) {
            return  // 空表无尾部
        }
        @Assert(data.size >= 12, true)
        let checksumSize = Int64(data[data.size - 4]) |
            (Int64(data[data.size - 3]) << 8) |
            (Int64(data[data.size - 2]) << 16) |
            (Int64(data[data.size - 1]) << 24)
        @Assert(checksumSize, 4)
        
        let stored = Int64(data[data.size - 8]) |
            (Int64(data[data.size - 7]) << 8) |
            (Int64(data[data.size - 6]) << 16) |
            (Int64(data[data.size - 5]) << 24)
        let crc = CRC32C()
        crc.write(data[0..(data.size - 8)])
        @Assert(Int64(crc.sum32()), stored)
    }
    
    @TestCase
    func testGoldenUncompressed() {
        let builder = TableBuilder(blockSize: 1024, bloomFalsePositive: 0.01)
        for (i in 0..300) {
            builder.add(orderedKey(i, 20),
                ValueStruct(Array<Byte>(80, {j => UInt8((i * 3 + j) % 256)}), version: UInt64(i + 1)))
        }
        let data = builder.finish()
        @Assert(fingerprint(data), GOLDEN_UNCOMPRESSED)
        assertTailContract(data)
    }
    
    @TestCase
    func testGoldenSnappy() {
        let builder = TableBuilder(blockSize: 1024, compression: CompressionType.Snappy)
        for (i in 0..300) {
            builder.add(orderedKey(i, 12),
                ValueStruct(Array<Byte>(200, repeat: UInt8(i % 7)), version: UInt64(i)))
        }
        let data = builder.finish()
        @Assert(fingerprint(data), GOLDEN_SNAPPY)
        assertTailContract(data)
    }
    
    @TestCase
    func testGoldenBigValue() {
        let builder = TableBuilder(blockSize: 4096)
        let bigVal = Array<Byte>(100 * 1024, {j => UInt8((j * 31) % 256)})
        builder.add("big".toArray(), ValueStruct(bigVal, version: 1))
        let data = builder.finish()
        @Assert(fingerprint(data), GOLDEN_BIGVALUE)
        assertTailContract(data)
    }
    
    @TestCase
    func testGoldenMultiVersionSameKey() {
        // 同 user key 500 个版本（key = "k1" + 8B ts，大端升序添加）跨多块
        let builder = TableBuilder(blockSize: 256)
        for (i in 0..500) {
            let key = Array<Byte>(11, repeat: 0u8)
            key[0] = 0x6Bu8
            key[1] = 0x31u8
            var v = UInt64(i + 1)
            var k = 10
            while (k >= 3) {
                key[k] = UInt8(v & 0xFF)
                v = v >> 8
                k--
            }
            builder.add(key, ValueStruct([UInt8(i % 256)], version: UInt64(i + 1)))
        }
        let data = builder.finish()
        @Assert(fingerprint(data), GOLDEN_MULTIVER)
        assertTailContract(data)
    }
    
    @TestCase
    func testEmptyTableFinishEmpty() {
        // L1 行为修正：空表 finish 返回空（调用方据此跳过建表/落盘）
        let builder = TableBuilder(blockSize: 1024)
        @Assert(builder.isEmpty(), true)
        let data = builder.finish()
        @Assert(data.size, 0)
    }
}
