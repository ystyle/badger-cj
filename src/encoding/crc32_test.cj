package badgercj.encoding

import std.unittest.*
import std.unittest.testmacro.*

@Test
class CRC32CTest {
    @TestCase
    func testEmpty() {
        let crc = CRC32C()
        let data = Array<Byte>(0, repeat: 0)
        crc.write(data)
        let result = crc.sum32()
        @Assert(result, 0u32)
    }
    
    @TestCase
    func testSingleByte() {
        let crc = CRC32C()
        let data: Array<Byte> = [0u8]
        crc.write(data)
        let result = crc.sum32()
        @Assert(result, 0x527D5351u32)
    }
    
    @TestCase
    func testHelloWorld() {
        let crc = CRC32C()
        let str = "Hello, World!"
        let data = str.toArray()
        crc.write(data)
        let result = crc.sum32()
        // CRC32-C value for "Hello, World!"
        @Assert(result, 0x4D551068u32)
    }
    
    @TestCase
    func testAllOnes() {
        let crc = CRC32C()
        let data: Array<Byte> = [0xFFu8, 0xFFu8, 0xFFu8, 0xFFu8]
        crc.write(data)
        let result = crc.sum32()
        @Assert(result > 0u32, true)
    }
    
    @TestCase
    func testReset() {
        let crc = CRC32C()
        crc.write([1u8, 2u8, 3u8, 4u8])
        let result1 = crc.sum32()
        
        crc.reset()
        crc.write([1u8, 2u8, 3u8, 4u8])
        let result2 = crc.sum32()
        
        @Assert(result1, result2)
    }
}