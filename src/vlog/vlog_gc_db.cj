package badgercj.vlog

import badgercj.table.*

/**
 * VLogGCDB - VLog GC 需要的数据库接口
 * 
 * 用于打破 Badger 和 VLogManager 的循环依赖
 */
protected interface VLogGCDB {
    func getVS(key: Array<Byte>): ?ValueStruct
    func setRaw(key: Array<Byte>, value: Array<Byte>, meta: Byte, version: UInt64, expiresAt: UInt64): Unit
    func getValueThreshold(): UInt64
}