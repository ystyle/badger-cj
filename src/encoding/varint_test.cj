package badgercj.encoding

import std.unittest.*
import std.unittest.testmacro.*

@Test
class VarintTest {
    @TestCase
    func testEncodeZero() {
        let encoded = Varint.encode(0u64)
        @Assert(encoded.size, 1)
        @Assert(encoded[0], 0u8)
    }
    
    @TestCase
    func testEncodeOne() {
        let encoded = Varint.encode(1u64)
        @Assert(encoded.size, 1)
        @Assert(encoded[0], 1u8)
    }
    
    @TestCase
    func testEncode127() {
        let encoded = Varint.encode(127u64)
        @Assert(encoded.size, 1)
        @Assert(encoded[0], 127u8)
    }
    
    @TestCase
    func testEncode128() {
        let encoded = Varint.encode(128u64)
        @Assert(encoded.size, 2)
        @Assert(encoded[0], 0x80u8)
        @Assert(encoded[1], 0x01u8)
    }
    
    @TestCase
    func testEncode300() {
        let encoded = Varint.encode(300u64)
        @Assert(encoded.size, 2)
        @Assert(encoded[0], 0xACu8)
        @Assert(encoded[1], 0x02u8)
    }
    
    @TestCase
    func testEncodeMaxUInt64() {
        let encoded = Varint.encode(UInt64.Max)
        @Assert(encoded.size, 10)
    }
    
    @TestCase
    func testDecodeZero() {
        let (value, size) = Varint.decode([0u8], 0)
        @Assert(value, 0u64)
        @Assert(size, 1)
    }
    
    @TestCase
    func testDecodeOne() {
        let (value, size) = Varint.decode([1u8], 0)
        @Assert(value, 1u64)
        @Assert(size, 1)
    }
    
    @TestCase
    func testDecode300() {
        let (value, size) = Varint.decode([0xACu8, 0x02u8], 0)
        @Assert(value, 300u64)
        @Assert(size, 2)
    }
    
    @TestCase
    func testRoundtrip() {
        let values: Array<UInt64> = [0u64, 1u64, 127u64, 128u64, 255u64, 256u64, 300u64, 
                                       16383u64, 16384u64, 2097151u64, 2097152u64, 
                                       268435455u64, 268435456u64, UInt64.Max]
        
        for (v in values) {
            let encoded = Varint.encode(v)
            let (decoded, size) = Varint.decode(encoded, 0)
            @Assert(decoded, v)
            @Assert(Int64(encoded.size), size)
        }
    }
    
    @TestCase
    func testDecodeOffset() {
        let data: Array<Byte> = [0xFFu8, 0xFFu8, 0xACu8, 0x02u8, 0xFFu8]
        let (value, size) = Varint.decode(data, 2)
        @Assert(value, 300u64)
        @Assert(size, 2)
    }
    
    @TestCase
    func testSize() {
        @Assert(Varint.size(0u64), 1)
        @Assert(Varint.size(127u64), 1)
        @Assert(Varint.size(128u64), 2)
        @Assert(Varint.size(16383u64), 2)
        @Assert(Varint.size(16384u64), 3)
        @Assert(Varint.size(UInt64.Max), 10)
    }
}