package badgercj.skiplist

/**
 * FFI 工具函数
 * 
 * 使用 @FastNative 优化 C 函数调用
 */

/**
 * memcmp - C 标准库内存比较
 * 
 * 使用 @FastNative 减少调用开销
 */
@FastNative
foreign func memcmp(s1: CPointer<Byte>, s2: CPointer<Byte>, n: UIntNative): Int32

/**
 * 快速内存比较
 * 
 * 使用 C 标准库的 memcmp，有 SIMD 优化
 * 仅用于长 key（>= 64 字节）
 */
@Frozen
protected func fastMemcmp(buf1: Array<Byte>, offset1: Int64, buf2: Array<Byte>, offset2: Int64, len: Int64): Int32 {
    unsafe {
        let handle1 = acquireArrayRawData(buf1)
        let handle2 = acquireArrayRawData(buf2)
        
        let ptr1 = handle1.pointer + offset1
        let ptr2 = handle2.pointer + offset2
        
        let result = memcmp(ptr1, ptr2, UIntNative(len))
        
        releaseArrayRawData(handle1)
        releaseArrayRawData(handle2)
        
        result
    }
}