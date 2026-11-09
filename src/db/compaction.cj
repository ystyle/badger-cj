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
        
        for (t in cd.top) {
            manifestChanges.add(ManifestChange(t.getId(), ManifestChangeOp.Delete, level: UInt32(cd.thisLevel)))
        }
        if (cd.thisLevel != cd.nextLevel) {
            for (t in cd.bot) {
                manifestChanges.add(ManifestChange(t.getId(), ManifestChangeOp.Delete, level: UInt32(cd.nextLevel)))
            }
        }
        
        // 顺序（对齐 badger-go runCompactDef）：
        //   ① 新表文件已落盘 → 先把 manifest 变更写下去（崩溃时以 manifest 为准，
        //      不会出现「旧表已删、新表还没登记」的丢数据窗口）；
        //   ② 原子替换下层（去掉被替换的 bot + 加入新表，同一锁段内完成）；
        //      先把新表装进下层、再摘除上层的 top —— 这期间读者在上层仍能找到数据，
        //      不存在「两层都看不到」的窗口；
        //   ③ 最后摘 top 并 close 被替换的旧表。
        let manifestFile = db.getManifestFile()
        manifestFile.saveChanges(manifestChanges)
        
        if (cd.thisLevel != cd.nextLevel) {
            let botIds = HashSet<UInt64>()
            for (t in cd.bot) {
                botIds.add(t.getId())
            }
            let removedBot = nextHandler.replaceTables(botIds, newTables)
            deleteTables(thisHandler, cd.top)
            for (t in removedBot) {
                t.close()
            }
        } else {
            let topIds = HashSet<UInt64>()
            for (t in cd.top) {
                topIds.add(t.getId())
            }
            let removed = thisHandler.replaceTables(topIds, newTables)
            for (t in removed) {
                t.close()
            }
        }
        
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
        // 保留策略（对齐 badger-go levels.go addKeys）：
        // - merge 条目永不丢弃（要等折叠后才能回收）；
        // - 版本号 > discardTs 的版本必须保留（活跃读者 / managed 旧 readTs 可能要读）；
        // - 版本号 <= discardTs 的版本，每个 key 至少保留 NumVersionsToKeep 个；
        //   discardTs = 活跃读事务最小 readTs（非 managed）或用户 setDiscardTs（managed）；
        // - 删除/过期条目：非最底层保留以压制低层；最底层可丢。两者都屏蔽更旧版本，一并丢。
        let discardTs = db.getDiscardTs()
        let numVersionsToKeep = Int64(db.getOpt().NumVersionsToKeep)
        var belowDiscardCount: Int64 = 0
        var skipRemainingVersions = false
        var firstVersionOfKey = true
        
        while (merger.valid()) {
            let key = merger.key()
            let vs = ValueStruct.decode(merger.value())
            // 换 key：重置版本保留计数（merger 可能复用 key 缓冲，lastKey 必须独立副本）
            if (lastKey.size == 0 || !sameKey(key, lastKey)) {
                lastKey = key.clone()
                belowDiscardCount = 0
                skipRemainingVersions = false
                firstVersionOfKey = true
            }
            let isFirstVersion = firstVersionOfKey
            firstVersionOfKey = false
            if (skipRemainingVersions) {
                Compaction.accumulateDiscard(discardStats, vs)
                merger.next()
                continue
            }
            let mergeEntry = (vs.meta & Meta.bitMergeEntry) != 0
            let eligible = vs.version <= discardTs && !mergeEntry
            if (!eligible) {
                // 活跃读者可能还要读 / merge 位条目要留给折叠：无条件保留
                builder.add(key, vs)
                // 首版本带 discard 位 = MergeOperator 回写的折叠结果：它下面的 merge 条目
                // 都已并入该值，本轮即可整体丢弃（否则那些带 merge 位的旧条目永不回收）
                if (isFirstVersion && (vs.meta & Meta.bitDiscardEarlierVersions) != 0) {
                    skipRemainingVersions = true
                }
                merger.next()
                continue
            }
            if (isDeletedOrExpired(vs.meta, vs.expiresAt)) {
                if (!bottomMost) {
                    // 非最底层：保留 tombstone 压制低层旧值（删数据复活事故的修复点）
                    builder.add(key, vs)
                } else {
                    Compaction.accumulateDiscard(discardStats, vs)
                }
                // 它屏蔽了同 key 的所有更旧版本
                skipRemainingVersions = true
                merger.next()
                continue
            }
            belowDiscardCount++
            if (belowDiscardCount <= numVersionsToKeep) {
                builder.add(key, vs)
                if ((vs.meta & Meta.bitDiscardEarlierVersions) != 0) {
                    skipRemainingVersions = true
                }
            } else {
                Compaction.accumulateDiscard(discardStats, vs)
            }
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
                Table(tableId, tableData: MmapTableData(path), cache: db.getBlockCache())
            } else {
                Table(tableId, data, cache: db.getBlockCache())
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
        let toDelete = HashSet<UInt64>()
        for (t in tables) {
            toDelete.add(t.getId())
        }
        // 原子摘除（一次锁段内重建列表）：不能 clear + 逐张 re-add——两个锁段之间
        // 读者会看到空列表，并发 get 偶发 miss（数据仍在库里）。
        handler.removeTables(toDelete)
        for (t in tables) {
            // 摘除即释放：读块是复制语义（TableData.read 返回新数组），此处没有并发
            // 读者持有表数据，因此无需引用计数（设计 §5.2 的免 refcount 方案）。
            // 磁盘表的映射在此解除，避免虚拟地址只增不减。
            t.close()
            // 回收磁盘文件：旧实现只解映射不删文件，磁盘随每轮 compaction 单调增长。
            // 顺序必须是「先 close 再 unlink」——Windows 上被映射的文件不能删除。
            // 删除失败不阻断 compaction：manifest 已移除该表，文件最迟由 open 时的
            // 孤儿清理回收（崩溃窗口同理：已建表但 MANIFEST 未记的文件）。
            let path = sstablePath(db.getOpt().Dir, t.getId())
            try {
                if (exists(Path(path))) {
                    remove(Path(path))
                }
            } catch (e: Exception) {
                // 忽略：文件可能在别的进程/句柄上仍占用
            }
        }
    }
}