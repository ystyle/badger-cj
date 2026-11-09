package badgercj.db

import std.sync.*
import std.collection.*
import std.fs.*
import std.io.*
import badgercj.table.*
import badgercj.manifest.*
import badgercj.utils.compareKeys

protected class Compaction {
    private let db: Badger
    private let lock: Mutex
    
    public init(db: Badger) {
        this.db = db
        this.lock = Mutex()
    }
    
    public func runCompaction(): Bool {
        lock.lock()
        try {
            let prioOpt = pickCompaction()
            if (prioOpt.isNone()) {
                return false
            }
            
            if (let Some(prio) <- prioOpt) {
                var cd = buildCompactDef(prio)
                if (let Some(filledCd) <- fillTables(cd)) {
                    doCompact(filledCd)
                    return true
                }
            }
            return false
        } finally {
            lock.unlock()
        }
    }
    
    private func buildCompactDef(prio: compactionPriority): compactDef {
        var cd = compactDef()
        cd.thisLevel = prio.level
        
        if (prio.level == 0) {
            cd.nextLevel = findBaseLevel()
        } else {
            let nextLevel = prio.level + 1
            if (nextLevel >= 7) {
                cd.nextLevel = prio.level
            } else {
                cd.nextLevel = nextLevel
            }
        }
        
        return cd
    }
    
    private func findBaseLevel(): Int {
        return 1
    }
    
    public func pickCompaction(): Option<compactionPriority> {
        let opt = db.getOpt()
        let l0Handler = db.getLevelHandler(0)
        let l0Count = l0Handler.numTables()
        
        if (l0Count > Int64(opt.NumLevelZeroTables)) {
            let score = Float64(l0Count) / Float64(opt.NumLevelZeroTables)
            return Some(compactionPriority(level: 0, score: score))
        }
        
        for (level in 1..opt.MaxLevels) {
            let handler = db.getLevelHandler(level)
            let size = handler.totalSize()
            let maxSize = Int64(opt.levelMaxSize(level))
            
            if (maxSize > 0 && size > maxSize) {
                let score = Float64(size) / Float64(maxSize)
                return Some(compactionPriority(level: level, score: score))
            }
        }
        
        return None
    }
    
    public func fillTables(cd: compactDef): Option<compactDef> {
        let thisHandler = db.getLevelHandler(cd.thisLevel)
        let nextHandler = db.getLevelHandler(cd.nextLevel)
        
        let tables = thisHandler.getTables()
        if (tables.size == 0) {
            return None
        }
        
        let cstatus = db.getCompactStatus()
        
        var top = ArrayList<TableInterface>()
        var thisRange = keyRange()
        var thisSize: Int64 = 0
        
        if (cd.thisLevel == 0) {
            for (t in tables) {
                let tRange = getKeyRange(t)
                thisRange.extendRange(tRange)
                thisSize += t.size()
                top.add(t)
            }
            
            if (cstatus.overlapsWith(cd.thisLevel, thisRange)) {
                return None
            }
        } else {
            let sortedTables = sortTablesByMaxVersion(tables)
            
            for (t in sortedTables) {
                let tSize = t.size()
                let tRange = getKeyRange(t)
                
                if (cstatus.overlapsWith(cd.thisLevel, tRange)) {
                    continue
                }
                
                top.add(t)
                thisSize = tSize
                thisRange = tRange
                break
            }
            
            if (top.size == 0) {
                return None
            }
        }
        
        var bot = ArrayList<TableInterface>()
        var nextRange = thisRange
        
        if (cd.thisLevel != cd.nextLevel) {
            let nextTables = nextHandler.getTables()
            
            for (nt in nextTables) {
                let ntRange = keyRange(
                    left: keyWithTs(parseKey(nt.smallest()), UInt64.Max),
                    right: keyWithTs(parseKey(nt.biggest()), 0)
                )
                if (thisRange.overlapsWith(ntRange)) {
                    bot.add(nt)
                }
            }
            
            if (bot.size > 0) {
                nextRange = getKeyRange(bot)
            }
            
            if (cd.thisLevel == 0 && cstatus.overlapsWith(cd.nextLevel, nextRange)) {
                return None
            }
        }
        
        var newCd = compactDef()
        newCd.thisLevel = cd.thisLevel
        newCd.nextLevel = cd.nextLevel
        newCd.thisRange = thisRange
        newCd.nextRange = nextRange
        newCd.thisSize = thisSize
        newCd.top = top
        newCd.bot = bot
        
        if (cstatus.compareAndAdd(newCd)) {
            return Some(newCd)
        }
        
        return None
    }
    
    public func getKeyRange(table: TableInterface): keyRange {
        let smallest = table.smallest()
        let biggest = table.biggest()
        
        keyRange(
            left: keyWithTs(parseKey(smallest), UInt64.Max),
            right: keyWithTs(parseKey(biggest), 0)
        )
    }
    
    public func getKeyRange(tables: ArrayList<TableInterface>): keyRange {
        if (tables.size == 0) {
            return keyRange()
        }
        
        var smallest = tables[0].smallest()
        var biggest = tables[0].biggest()
        
        for (i in 1..tables.size) {
            if (compareKeys(tables[i].smallest(), smallest) < 0) {
                smallest = tables[i].smallest()
            }
            if (compareKeys(tables[i].biggest(), biggest) > 0) {
                biggest = tables[i].biggest()
            }
        }
        
        keyRange(
            left: keyWithTs(parseKey(smallest), UInt64.Max),
            right: keyWithTs(parseKey(biggest), 0)
        )
    }
    
    private func sortTablesByMaxVersion(tables: ArrayList<TableInterface>): ArrayList<TableInterface> {
        let sorted = ArrayList<TableInterface>()
        for (t in tables) {
            sorted.add(t)
        }
        
        var i: Int64 = 0
        while (i < sorted.size - 1) {
            var j: Int64 = i + 1
            while (j < sorted.size) {
                if (sorted[i].getMaxVersion() > sorted[j].getMaxVersion()) {
                    let tmp = sorted[i]
                    sorted[i] = sorted[j]
                    sorted[j] = tmp
                }
                j++
            }
            i++
        }
        
        return sorted
    }
    
    private func doCompact(cd: compactDef): Bool {
        let cstatus = db.getCompactStatus()
        
        let thisHandler = db.getLevelHandler(cd.thisLevel)
        let nextHandler = db.getLevelHandler(cd.nextLevel)
        
        let (newTables, manifestChanges) = compactBuildTables(cd, cd.nextLevel)
        
        for (t in newTables) {
            nextHandler.addTable(t)
        }
        
        for (t in cd.top) {
            manifestChanges.add(ManifestChange(t.getId(), ManifestChangeOp.Delete, level: UInt32(cd.thisLevel)))
        }
        if (cd.thisLevel != cd.nextLevel) {
            for (t in cd.bot) {
                manifestChanges.add(ManifestChange(t.getId(), ManifestChangeOp.Delete, level: UInt32(cd.nextLevel)))
            }
        }
        
        deleteTables(thisHandler, cd.top)
        if (cd.thisLevel != cd.nextLevel) {
            deleteTables(nextHandler, cd.bot)
        }
        
        let manifestFile = db.getManifestFile()
        manifestFile.saveChanges(manifestChanges)
        
        cstatus.delete(cd)
        return true
    }
    
    private func compactBuildTables(cd: compactDef, level: Int): (ArrayList<TableInterface>, ManifestChangeSet) {
        let result = ArrayList<TableInterface>()
        let manifestChanges = ManifestChangeSet()
        
        let builder = TableBuilder(bloomFalsePositive: db.getOpt().BloomFalsePositive, compression: db.getOpt().Compression)
        // k 路归并输入：各表本身按键有序，流式合并即可，不必把 top+bot 全表读进
        // ArrayList 再冒泡排序（旧实现峰值内存 O(总条目数)、时间 O(n²)）。
        let mergeIters = ArrayList<SimpleIterator>()
        for (t in cd.top) {
            mergeIters.add(TableIterWrapper(t.newIterator()))
        }
        for (t in cd.bot) {
            mergeIters.add(TableIterWrapper(t.newIterator()))
        }
        let merger = MergeIterator(mergeIters)
        merger.rewind()
        var lastKey: Array<Byte> = []
        // 本轮丢弃的旧版本里，值在 vlog 中的字节数按 fid 累计——VLog GC 靠它判断哪段垃圾多。
        let discardStats = HashMap<UInt32, Int64>()
        // 只有合并到**最底层**时，删除标记才可以真正丢弃：更低层若还留着更旧的版本，
        // 丢掉 tombstone 等于给旧值解禁（生产实测：某次 2MB compaction 之后，删掉的上游
        // 记录整批复活，连 id 都不变）。非最底层一律把 tombstone 写进新表继续压制。
        let bottomMost = cd.nextLevel >= db.getOpt().MaxLevels - 1
        
        while (merger.valid()) {
            let key = merger.key()
            let vs = ValueStruct.decode(merger.value())
            // 同一个 key 的后续条目都是更旧的版本：**无论上一条有没有被写入**都要跳过。
            // 必须先判重再更新 lastKey —— 反过来的话，「丢弃 tombstone」的同一轮里更旧的
            // 值会被当成新 key 写进新表，就是删除复活的机制。
            if (lastKey.size > 0 && sameKey(key, lastKey)) {
                Compaction.accumulateDiscard(discardStats, vs)
                merger.next()
                continue
            }
            // merger 可能复用 key 缓冲，lastKey 必须持有独立副本
            lastKey = key.clone()
            if (isDeletedOrExpired(vs.meta, vs.expiresAt) && bottomMost) {
                Compaction.accumulateDiscard(discardStats, vs)
                merger.next()
                continue
            }
            builder.add(key, vs)
            merger.next()
        }
        
        let data = builder.finish()
        if (data.size > 0) {
            // 表 id 必须取文件序列（对齐 badger-go reserveFileID）：此前误用 db.getVersion()
            // （提交版本号计数器）→ 与 flush/close 的文件 id 序列重叠、同版本重复 compaction
            // 会覆写同一 id 文件 + manifest 同 id 双记录（deleteTables 按 id 误删风险）
            let tableId = db.reserveFileID()
            let path = sstablePath(db.getOpt().Dir, tableId)
            // 写失败抛异常（由 compactor 外层捕获记录，不杀协程、不留半落盘表）
            writeFile(path, data, useIoUring: db.getOpt().UseIoUring)
            
            // 已落盘：改用只读映射（构建产物 data 至此可弃）
            let table = if (db.getOpt().MmapSSTable) {
                Table(tableId, tableData: MmapTableData(path))
            } else {
                Table(tableId, data)
            }
            result.add(TableAdapter(table))
            manifestChanges.add(ManifestChange(tableId, ManifestChangeOp.Create, level: UInt32(level)))
        }
        
        // 统计必须在本轮结束前交给 VLogManager（Go 同位置：compactBuildTables 末尾 updateDiscardStats）
        db.updateVLogDiscardStats(discardStats)
        
        (result, manifestChanges)
    }
    
    /** 丢弃条目时累计其 vlog 占用（仅值指针条目有 vlog 字节）。 */
    private static func accumulateDiscard(stats: HashMap<UInt32, Int64>, vs: ValueStruct): Unit {
        if (!vs.isValuePointer()) {
            return
        }
        let vp = ValuePointer.decode(vs.value)
        let current: Int64 = if (stats.contains(vp.fid)) { stats[vp.fid] } else { 0 }
        stats[vp.fid] = current + Int64(vp.len)
    }
    
    private func deleteTables(handler: LevelHandler, tables: ArrayList<TableInterface>): Unit {
        let currentTables = handler.getTables()
        let toDelete = HashSet<UInt64>()
        for (t in tables) {
            toDelete.add(t.getId())
        }
        
        handler.clearTables()
        for (t in currentTables) {
            if (!toDelete.contains(t.getId())) {
                handler.addTable(t)
            } else {
                // 摘除即释放：读块是复制语义（TableData.read 返回新数组），此处没有并发
                // 读者持有表数据，因此无需引用计数（设计 §5.2 的免 refcount 方案）。
                // 磁盘表的映射在此解除，避免虚拟地址只增不减。
                t.close()
            }
        }
    }
}