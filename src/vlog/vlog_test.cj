package badgercj.vlog

import std.unittest.*
import std.unittest.testmacro.*

@Test
class LogEntryTest {
    @TestCase
    func testEncodeDecode() {
        let key: Array<Byte> = [1, 2, 3]
        let value: Array<Byte> = [10, 20, 30]
        let entry = LogEntry(key, value)
        
        let encoded = entry.encode()
        @Assert(encoded.size > 0, true)
        
        let (decoded, _) = LogEntry.decode(encoded, 0)
        @Assert(decoded.key.size, 3)
        @Assert(decoded.value.size, 3)
    }
    
    @TestCase
    func testEncodeDecodeWithMeta() {
        let entry = LogEntry([1u8], [2u8], meta: 0x01)
        let encoded = entry.encode()
        
        let (decoded, _) = LogEntry.decode(encoded, 0)
        @Assert(decoded.meta, 0x01)
    }
    
    @TestCase
    func testChecksum() {
        let entry1 = LogEntry([1u8], [2u8])
        let entry2 = LogEntry([1u8], [3u8])
        
        let encoded1 = entry1.encode()
        let encoded2 = entry2.encode()
        
        @Assert(encoded1.size != encoded2.size || encoded1 != encoded2, true)
    }
    
    @TestCase
    func testLargeEntry() {
        let key = Array<Byte>(100, {i => UInt8(i % 256)})
        let value = Array<Byte>(1000, {i => UInt8(i % 256)})
        let entry = LogEntry(key, value)
        
        let encoded = entry.encode()
        @Assert(encoded.size > 1100, true)
        
        let (decoded, _) = LogEntry.decode(encoded, 0)
        @Assert(decoded.key.size, 100)
        @Assert(decoded.value.size, 1000)
    }
}
