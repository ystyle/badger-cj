package badgercj.db

import badgercj.table.*
import badgercj.manifest.*
import std.collection.*
import std.fs.*
import std.io.*
import badgercj.utils.compareKeys

protected class LevelsController {
    private let levels: ArrayList<LevelHandler>
    private let manifest: Manifest
    private let dir: String
    private let nextFileID: UInt64
    private let cstatus: compactStatus
    private let inMemory: Bool
    private let memoryTables: HashMap<UInt64, Array<Byte>>
    private let mmapSSTable: Bool
    private let blockCache: ?BlockCache
    
    public init(manifest!: Manifest = Manifest(), dir!: String = "", inMemory!: Bool = false,
        mmapSSTable!: Bool = true, blockCache!: ?BlockCache = None) {
        this.manifest = manifest
        this.dir = dir
        this.inMemory = inMemory
        this.mmapSSTable = mmapSSTable
        this.blockCache = blockCache
        this.nextFileID = manifest.nextFileID
        this.levels = ArrayList<LevelHandler>()
        this.cstatus = compactStatus(7)
        this.memoryTables = HashMap<UInt64, Array<Byte>>()
        
        for (i in 0..7) {
            levels.add(LevelHandler(i))
        }
        
        // 加载现有 SST 文件
        if (!inMemory && !dir.isEmpty()) {
            loadTables()
        }
    }
    
    /** 释放所有表的底层资源（磁盘表解除映射）。close() 时调用，避免反复 open/close 累积虚拟地址。 */
    public func closeTables(): Unit {
        for (handler in levels) {
            for (t in handler.getTables()) {
                t.close()
            }
        }
    }
    
    public func get(key: Array<Byte>, readTs: UInt64): Option<ValueStruct> {
        for (handler in levels) {
            let vs = handler.get(key, readTs)
            match (vs) {
                case Some(v) => return vs
                case None => continue
            }
        }
        return None
    }
    
    public func addTable(level: Int, table: TableInterface): Unit {
        if (level < 0 || level >= levels.size) {
            return
        }
        levels[level].addTable(table)
    }
    
    public func addMemoryTable(id: UInt64, data: Array<Byte>): Unit {
        memoryTables[id] = data
        let table = Table(id, data, inMemory: true)
        levels[0].addTable(TableAdapter(table))
    }
    
    public func getLevelHandler(level: Int): LevelHandler {
        return levels[level]
    }
    
    public func numLevels(): Int64 {
        return levels.size
    }
    
    public func getNextFileID(): UInt64 {
        return nextFileID
    }
    
    public func getCompactStatus(): compactStatus {
        return cstatus
    }
    
    public func getDir(): String {
        dir
    }
    
    public func appendIterators(iters: ArrayList<SimpleIterator>, opt: IteratorOptions): Unit {
        for (handler in levels) {
            handler.appendIterators(iters, opt)
        }
    }
    
    public func loadTables(): Unit {
        for (level in 0..7) {
            let tables = manifest.levels[level]
            for (tableInfo in tables) {
                let path = sstablePath(dir, tableInfo.id)
                if (exists(Path(path))) {
                    // 默认映射打开（表数据留在页缓存，不进 GC 堆）；关闭则退回整表读入
                    let table = if (mmapSSTable) {
                        Table(tableInfo.id, tableData: MmapTableData(path), cache: blockCache)
                    } else {
                        Table(tableInfo.id, File.readFrom(Path(path)), cache: blockCache)
                    }
                    let adapter = TableAdapter(table)
                    levels[level].addTable(adapter)
                }
            }
        }
        
        // 打开时回收孤儿 .sst：① 崩溃窗口里「已建表但 MANIFEST 未记录」；
        // ② 旧版本 compaction 只解映射、不 unlink 留下的旧表。只删 manifest 中
        // 不存在的数字命名文件，非标准命名一律不动。
        cleanupStaleTables()
    }
    
    private func cleanupStaleTables(): Unit {
        if (inMemory || dir.isEmpty()) {
            return
        }
        // 目录可以还不存在（例如仅用默认值构造 LevelsController 的场景）
        if (!exists(Path(dir))) {
            return
        }
        let live = HashSet<UInt64>()
        for (levelTables in manifest.levels) {
            for (info in levelTables) {
                live.add(info.id)
            }
        }
        for (entry in Directory.readFrom(Path(dir))) {
            let name = entry.name
            if (!name.endsWith(".sst")) {
                continue
            }
            let stem = name[0..(name.size - 4)]
            if (stem.size == 0 || stem.size > 20) {
                continue
            }
            var id: UInt64 = 0
            var digitsOnly = true
            for (b in stem.toArray()) {
                if (b < 48 || b > 57) {
                    digitsOnly = false
                    break
                }
                id = id * 10 + UInt64(b - 48)
            }
            if (digitsOnly && !live.contains(id)) {
                try {
                    remove(Path(dir + "/" + name))
                } catch (e: Exception) {
                }
            }
        }
    }
    
protected func getMaxVersion(): UInt64 {
        var maxVer: UInt64 = 0
        for (handler in levels) {
            let ver = handler.getMaxVersion()
            if (ver > maxVer) {
                maxVer = ver
            }
        }
        return maxVer
    }
    
    public func getTableInfo(): ArrayList<SSTableInfo> {
        let result = ArrayList<SSTableInfo>()
        for (level in 0..levels.size) {
            let infos = levels[level].getTableInfo(level)
            for (info in infos) {
                result.add(info)
            }
        }
        return result
    }
    
    public func getLevelInfo(): ArrayList<LevelInfo> {
        let result = ArrayList<LevelInfo>()
        for (level in 0..levels.size) {
            let handler = levels[level]
            let info = LevelInfo(
                level: level,
                numTables: handler.numTables(),
                size: handler.totalSize(),
                targetSize: Int64(levelMaxSize(level))
            )
            result.add(info)
        }
        return result
    }
    
    private func levelMaxSize(level: Int): UInt64 {
        if (level == 0) {
            return UInt64(4) * 2 * 1024 * 1024u64
        }
        return 2 * 1024 * 1024u64 * UInt64(1 << ((level - 1) * 2))
    }
    
    public func keySplits(numPerTable: Int64, prefix: Array<Byte>): ArrayList<Array<Byte>> {
        let splits = ArrayList<Array<Byte>>()
        for (handler in levels) {
            let tables = handler.getTables()
            for (table in tables) {
                let tableSplits = table.keySplits(numPerTable, prefix)
                for (s in tableSplits) {
                    splits.add(s)
                }
            }
        }
        sortSplits(splits)
        splits
    }
    
    private func sortSplits(splits: ArrayList<Array<Byte>>): Unit {
        for (i in 0..splits.size) {
            for (j in i + 1..splits.size) {
                if (compareKeys(splits[i], splits[j]) > 0) {
                    let tmp = splits[i]
                    splits[i] = splits[j]
                    splits[j] = tmp
                }
            }
        }
    }
}
