package badgercj.db

import badgercj.arena.{MAX_NODE_SIZE}

/**
 * MemTable arena 目标容量（唯一来源：MemTable 与 Badger 都调用这里，避免公式漂移）。
 *
 *   目标 = MemTableSize + 批次预留 + (批次预留 / 96) × 节点大小
 *
 * 为什么需要批次预留：一次 putBatch（分组提交的一批写请求）可能整批跨过轮换阈值，
 * 预留保证这批能整批放进当前表而不必中途轮换；节点项覆盖这批条目的 skiplist 节点开销
 *（≈106B/条，不含在「已用字节」统计里）。
 *
 * 2.3 起预留改为 `min(15% × MemTableSize, 2MB)`：原公式按 15% 走，64MB 表就是 20.6MB，
 * 而实测单批最大预留只有 28KB~1.65MB（128B/1KB/16KB 值 × 100~1000 条/事务）——
 * 那部分平时不用，却是实打实的 GC 堆占用（arena 是 Array<Byte>）。
 * `Config.MemTableBatchReserveBytes > 0` 时按显式值（上限 MemTableSize）。
 */
protected func arenaTargetBytes(opt: Config): Int64 {
    let memTableSize = Int64(opt.MemTableSize)
    let reserve = arenaBatchReserveBytes(opt)
    var batchCount = reserve / 96
    if (batchCount < 1) {
        batchCount = 1
    }
    memTableSize + reserve + batchCount * MAX_NODE_SIZE
}

/** 批次预留字节（见 arenaTargetBytes）。 */
protected func arenaBatchReserveBytes(opt: Config): Int64 {
    let memTableSize = Int64(opt.MemTableSize)
    var reserve = Int64(opt.MemTableBatchReserveBytes)
    if (reserve <= 0) {
        // 默认：15% 封顶 2MB（小表按 15% 走；1KB 下限让极小表也有批次余量）
        reserve = memTableSize * 15 / 100
        let cap: Int64 = 2 * 1024 * 1024
        if (reserve > cap) {
            reserve = cap
        }
    }
    if (reserve < 1024) {
        reserve = 1024
    }
    if (reserve > memTableSize) {
        reserve = memTableSize
    }
    reserve
}
