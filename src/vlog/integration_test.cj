package badgercj.vlog

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import badgercj.table.ValuePointer

@Test
class ValueLogIntegrationTest {
    
    @TestCase
    func testWriteAndRead() {
        let vlog = ValueLog()
        
        let key: Array<Byte> = [1u8, 2u8, 3u8]
        let value: Array<Byte> = [10u8, 20u8, 30u8]
        let entry = LogEntry(key, value)
        
        let vp = vlog.write(entry)
        
        @Assert(vp.offset, 0)
        @Assert(vp.len > 0, true)
        
        let readEntry = vlog.read(vp)
        @Assert(readEntry.key.size, 3)
        @Assert(readEntry.value.size, 3)
        @Assert(readEntry.key[0], 1u8)
        @Assert(readEntry.value[0], 10u8)
    }
    
    @TestCase
    func testMultipleWrites() {
        let vlog = ValueLog()
        
        let entries: ArrayList<(Array<Byte>, Array<Byte>)> = ArrayList<(Array<Byte>, Array<Byte>)>()
        let vps: ArrayList<ValuePointer> = ArrayList<ValuePointer>()
        
        for (i in 0..10) {
            let key = Array<Byte>(8, {j => UInt8(i * 10 + j)})
            let value = Array<Byte>(16, {j => UInt8(i * 20 + j)})
            entries.add((key, value))
            
            let entry = LogEntry(key, value)
            let vp = vlog.write(entry)
            vps.add(vp)
        }
        
        for (i in 0..10) {
            let (key, expectedValue) = entries[i]
            let vp = vps[i]
            
            let readEntry = vlog.read(vp)
            
            @Assert(readEntry.key.size, key.size)
            @Assert(readEntry.value.size, expectedValue.size)
            
            for (j in 0..readEntry.key.size) {
                @Assert(readEntry.key[j], key[j])
            }
            for (j in 0..readEntry.value.size) {
                @Assert(readEntry.value[j], expectedValue[j])
            }
        }
    }
    
    @TestCase
    func testLargeValue() {
        let vlog = ValueLog()
        
        let key: Array<Byte> = [1u8]
        let largeValue = Array<Byte>(10000, {i => UInt8(i % 256)})
        
        let entry = LogEntry(key, largeValue)
        let vp = vlog.write(entry)
        
        let readEntry = vlog.read(vp)
        @Assert(readEntry.value.size, 10000)
        
        for (i in 0..readEntry.value.size) {
            @Assert(readEntry.value[i], UInt8(i % 256))
        }
    }
    
    @TestCase
    func testSequentialOffsets() {
        let vlog = ValueLog()
        
        let vp1 = vlog.write(LogEntry([1u8], [10u8]))
        let vp2 = vlog.write(LogEntry([2u8], [20u8]))
        let vp3 = vlog.write(LogEntry([3u8], [30u8]))
        
        @Assert(vp1.offset, 0u32)
        @Assert(vp2.offset > vp1.offset, true)
        @Assert(vp3.offset > vp2.offset, true)
        
        @Assert(vlog.size() > 0, true)
    }
    
    @TestCase
    func testValuePointerEncoding() {
        let vp = ValuePointer(123u32, 456u32, 789u32)
        
        @Assert(vp.fid, 123u32)
        @Assert(vp.len, 456u32)
        @Assert(vp.offset, 789u32)
    }
    
    @TestCase
    func testEmptyValue() {
        let vlog = ValueLog()
        
        let entry = LogEntry([1u8, 2u8], [])
        let vp = vlog.write(entry)
        
        let readEntry = vlog.read(vp)
        @Assert(readEntry.key.size, 2)
        @Assert(readEntry.value.size, 0)
    }
    
    @TestCase
    func testEmptyKey() {
        let vlog = ValueLog()
        
        let entry = LogEntry([], [1u8, 2u8, 3u8])
        let vp = vlog.write(entry)
        
        let readEntry = vlog.read(vp)
        @Assert(readEntry.key.size, 0)
        @Assert(readEntry.value.size, 3)
    }
    
    @TestCase
    func testWithMeta() {
        let vlog = ValueLog()
        
        let entry = LogEntry([1u8], [2u8], meta: 0xFF)
        let vp = vlog.write(entry)
        
        let readEntry = vlog.read(vp)
        @Assert(readEntry.meta, 0xFF)
    }
    
    @TestCase
    func testWriteReadRandomOrder() {
        let vlog = ValueLog()
        
        let vps: HashMap<Int64, ValuePointer> = HashMap<Int64, ValuePointer>()
        let values: HashMap<Int64, Array<Byte>> = HashMap<Int64, Array<Byte>>()
        
        for (i in 0..20) {
            let id = Int64(i * 3 % 20)
            let key = Array<Byte>(4, {j => UInt8((id + j) % 256)})
            let value = Array<Byte>(8, {j => UInt8((id * 2 + j) % 256)})
            
            let entry = LogEntry(key, value)
            let vp = vlog.write(entry)
            
            vps[id] = vp
            values[id] = value
        }
        
        for ((id, expectedValue) in values) {
            let vp = vps[id]
            let readEntry = vlog.read(vp)
            
            @Assert(readEntry.value.size, expectedValue.size)
            for (j in 0..readEntry.value.size) {
                @Assert(readEntry.value[j], expectedValue[j])
            }
        }
    }
}
