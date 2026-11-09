package badgercj.vlog

import std.collection.*
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
    /** 把一组活值写回数据库（走正常写路径：大值重新写入新 vlog 段并更新指针）。 */
    func rewriteBatch(entries: ArrayList<(Array<Byte>, Array<Byte>, Byte, UInt64)>): Unit
    /** DB 是否已关闭（GC 期间避免与 close 竞争）。 */
    func isClosed(): Bool
}