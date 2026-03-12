package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.io.*
import std.time.*

@Test
class BufferBench {
    
    private static let iterations = 10000
    private static let keySize = 16
    private static let ts: UInt64 = 12345
    
    // 防止编译器优化
    private static var sink: Array<Byte> = []
    
    @Bench
    func benchArrayListAdd() {
        for (_ in 0..BufferBench.iterations) {
            let result = ArrayList<Byte>()
            
            // 模拟 keyWithTs 的操作
            for (i in 0..BufferBench.keySize) {
                result.add(UInt8(i % 256))
            }
            
            // 添加 8 字节时间戳
            let invTs = 0xFFFFFFFFFFFFFFFFu64 ^ BufferBench.ts
            result.add(UInt8((invTs >> 56) & 0xFF))
            result.add(UInt8((invTs >> 48) & 0xFF))
            result.add(UInt8((invTs >> 40) & 0xFF))
            result.add(UInt8((invTs >> 32) & 0xFF))
            result.add(UInt8((invTs >> 24) & 0xFF))
            result.add(UInt8((invTs >> 16) & 0xFF))
            result.add(UInt8((invTs >> 8) & 0xFF))
            result.add(UInt8(invTs & 0xFF))
            
            BufferBench.sink = result.toArray()
        }
    }
    
    @Bench
    func benchArrayDirect() {
        for (_ in 0..BufferBench.iterations) {
            let result = Array<Byte>(BufferBench.keySize + 8, repeat: 0)
            
            // 复制 key
            for (i in 0..BufferBench.keySize) {
                result[i] = UInt8(i % 256)
            }
            
            // 添加 8 字节时间戳
            let invTs = 0xFFFFFFFFFFFFFFFFu64 ^ BufferBench.ts
            result[BufferBench.keySize] = UInt8((invTs >> 56) & 0xFF)
            result[BufferBench.keySize + 1] = UInt8((invTs >> 48) & 0xFF)
            result[BufferBench.keySize + 2] = UInt8((invTs >> 40) & 0xFF)
            result[BufferBench.keySize + 3] = UInt8((invTs >> 32) & 0xFF)
            result[BufferBench.keySize + 4] = UInt8((invTs >> 24) & 0xFF)
            result[BufferBench.keySize + 5] = UInt8((invTs >> 16) & 0xFF)
            result[BufferBench.keySize + 6] = UInt8((invTs >> 8) & 0xFF)
            result[BufferBench.keySize + 7] = UInt8(invTs & 0xFF)
            
            BufferBench.sink = result
        }
    }
    
    @Bench
    func benchByteBufferWrite() {
        for (_ in 0..BufferBench.iterations) {
            let buf = ByteBuffer(BufferBench.keySize + 8)
            
            // 写入 key
            let key = Array<Byte>(BufferBench.keySize, {i => UInt8(i % 256)})
            buf.write(key)
            
            // 写入 8 字节时间戳
            let invTs = 0xFFFFFFFFFFFFFFFFu64 ^ BufferBench.ts
            buf.writeByte(UInt8((invTs >> 56) & 0xFF))
            buf.writeByte(UInt8((invTs >> 48) & 0xFF))
            buf.writeByte(UInt8((invTs >> 40) & 0xFF))
            buf.writeByte(UInt8((invTs >> 32) & 0xFF))
            buf.writeByte(UInt8((invTs >> 24) & 0xFF))
            buf.writeByte(UInt8((invTs >> 16) & 0xFF))
            buf.writeByte(UInt8((invTs >> 8) & 0xFF))
            buf.writeByte(UInt8(invTs & 0xFF))
            
            BufferBench.sink = buf.bytes()
        }
    }
    
    @Bench
    func benchByteBufferWriteBytes() {
        for (_ in 0..BufferBench.iterations) {
            let buf = ByteBuffer(BufferBench.keySize + 8)
            
            // 写入 key
            let key = Array<Byte>(BufferBench.keySize, {i => UInt8(i % 256)})
            buf.write(key)
            
            // 写入 8 字节时间戳（一次性写入）
            let invTs = 0xFFFFFFFFFFFFFFFFu64 ^ BufferBench.ts
            let tsBytes = Array<Byte>(8, {i => 
                UInt8((invTs >> UInt64(56 - i * 8)) & 0xFF)
            })
            buf.write(tsBytes)
            
            BufferBench.sink = buf.bytes()
        }
    }
}