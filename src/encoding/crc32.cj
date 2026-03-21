/**
 * CRC32-C (Castagnoli) 实现
 */
package badgercj.encoding

import std.collection.*
import std.binary.*
import badgercj.utils.u32ToLE

public const CastagnoliPoly: UInt32 = 0x82F63B78u32

@OverflowWrapping
private func makeTable(poly: UInt32): ArrayList<UInt32> {
    let table = ArrayList<UInt32>()
    
    for (i in 0..256) {
        var crc: UInt32 = UInt32(i)
        
        for (_ in 0..8) {
            if ((crc & 1u32) != 0u32) {
                crc = (crc >> 1u32) ^ poly
            } else {
                crc = crc >> 1u32
            }
        }
        
        table.add(crc)
    }
    
    return table
}

private let globalTable: ArrayList<UInt32> = makeTable(CastagnoliPoly)

public class CRC32C {
    private var crc: UInt32

    public init() {
        this.crc = 0u32
    }

    public func size(): Int64 {
        return 4
    }

    public func reset(): Unit {
        this.crc = 0u32
    }

    @OverflowWrapping
    public func write(p: Array<Byte>): Int64 {
        var c: UInt32 = this.crc ^ 0xFFFFFFFFu32
        for (b in p) {
            let idx: UInt32 = (c ^ UInt32(b)) & 0xFFu32
            let tableVal = globalTable[Int64(idx)]
            c = (c >> 8u32) ^ tableVal
        }
        this.crc = c ^ 0xFFFFFFFFu32
        return p.size
    }

    @OverflowWrapping
    public func writeByte(b: Byte): Unit {
        var c: UInt32 = this.crc ^ 0xFFFFFFFFu32
        let idx: UInt32 = (c ^ UInt32(b)) & 0xFFu32
        let tableVal = globalTable[Int64(idx)]
        c = (c >> 8u32) ^ tableVal
        this.crc = c ^ 0xFFFFFFFFu32
    }

    public func sum32(): UInt32 {
        return this.crc
    }

    public func sum(): Array<Byte> {
        return u32ToLE(this.crc)
    }
}

@OverflowWrapping
public func checksumCRC32C(data: Array<Byte>): UInt32 {
    var c: UInt32 = 0xFFFFFFFFu32
    for (b in data) {
        let idx: UInt32 = (c ^ UInt32(b)) & 0xFFu32
        c = (c >> 8u32) ^ globalTable[Int64(idx)]
    }
    return c ^ 0xFFFFFFFFu32
}