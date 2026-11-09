package badgercj.db

import badgercj.table.*
import std.collection.*
import std.sync.*
import badgercj.utils.compareKeys

protected class LevelHandler {
    private let level: Int
    private var tables: ArrayList<TableInterface>
    private let lock: Mutex
    
    public init(level: Int) {
        this.level = level
        this.tables = ArrayList<TableInterface>()
        this.lock = Mutex()
    }
    
    public func addTable(table: TableInterface): Unit {
        synchronized(lock) {
            tables.add(table)
        }
    }
    
    public func getTables(): ArrayList<TableInterface> {
        synchronized(lock) {
            let result = ArrayList<TableInterface>()
            for (t in tables) {
                result.add(t)
            }
            return result
        }
    }
    
    public func get(key: Array<Byte>, readTs: UInt64): Option<ValueStruct> {
        if (level == 0) {
            return getL0(key, readTs)
        } else {
            return getL1Plus(key, readTs)
        }
    }
    
    private func getL0(key: Array<Byte>, readTs: UInt64): Option<ValueStruct> {
        synchronized(lock) {
            var i: Int64 = tables.size - 1
            while (i >= 0) {
                let table = tables[i]
                let vs = table.get(key, readTs)
                match (vs) {
                    case Some(v) => return vs
                    case None => i--
                }
            }
            return None
        }
    }
    
    private func getL1Plus(key: Array<Byte>, readTs: UInt64): Option<ValueStruct> {
        synchronized(lock) {
            let idx = findTable(key)
            if (idx < 0) {
                return None
            }
            
            let table = tables[idx]
            return table.get(key, readTs)
        }
    }
    
    private func findTable(key: Array<Byte>): Int64 {
        var left: Int64 = 0
        var right: Int64 = tables.size - 1
        
        while (left <= right) {
            let mid = left + (right - left) / 2
            let table = tables[mid]
            
            let smallest = parseKey(table.smallest())
            let biggest = parseKey(table.biggest())
            
            if (compareKeys(key, smallest) < 0) {
                right = mid - 1
            } else if (compareKeys(key, biggest) > 0) {
                left = mid + 1
            } else {
                return mid
            }
        }
        
        return -1
    }
    
    public func numTables(): Int64 {
        synchronized(lock) {
            return tables.size
        }
    }
    
    public func totalSize(): Int64 {
        synchronized(lock) {
            var total: Int64 = 0
            for (t in tables) {
                total += t.size()
            }
            return total
        }
    }
    
    public func clearTables(): Unit {
        synchronized(lock) {
            tables.clear()
        }
    }
    
    /**
     * 原子摘除一批表（compaction 用）：一次锁内重建列表。
     *
     * 不能写成「clearTables() 然后逐张 addTable()」——那是两个锁段，读者可能在中间
     * 看到**空表列表**，此时 get 直接返回 None（实测：compaction 与并发读重叠时，
     * 存在 key 在库里但 get 偶发 miss、下一次再读又命中）。列表替换必须对读者原子。
     */
    public func removeTables(toDelete: HashSet<UInt64>): Unit {
        synchronized(lock) {
            let kept = ArrayList<TableInterface>()
            for (t in tables) {
                if (!toDelete.contains(t.getId())) {
                    kept.add(t)
                }
            }
            tables = kept
        }
    }
    
    /**
     * 原子替换一批表（compaction 装表用）：一次锁内 = 去掉 toDelete + 加入 toAdd + 按
     * smallest 排序；返回被摘除的表（调用方负责 close）。
     *
     * 为什么必须原子：L1+ 的读路径用 findTable 二分（要求本层表**不重叠且有序**）。
     * 若先 addTable(new) 再删旧表，中间窗口本层存在重叠表，二分可能落在旧表上返回
     * None（数据其实在新表里）——实测：compaction 与并发读重叠时 get 偶发 miss。
     */
    public func replaceTables(toDelete: HashSet<UInt64>, toAdd: ArrayList<TableInterface>): ArrayList<TableInterface> {
        synchronized(lock) {
            let removed = ArrayList<TableInterface>()
            let kept = ArrayList<TableInterface>()
            for (t in tables) {
                if (toDelete.contains(t.getId())) {
                    removed.add(t)
                } else {
                    kept.add(t)
                }
            }
            for (t in toAdd) {
                kept.add(t)
            }
            // 按 smallest 升序（二分查找前提）；表数量为个位~几十，插入排序足够
            var i: Int64 = 1
            while (i < kept.size) {
                let cur = kept[i]
                var j = i - 1
                while (j >= 0 && compareKeys(kept[j].smallest(), cur.smallest()) > 0) {
                    kept[j + 1] = kept[j]
                    j--
                }
                kept[j + 1] = cur
                i++
            }
            tables = kept
            return removed
        }
    }
    
    public func appendIterators(iters: ArrayList<SimpleIterator>, opt: IteratorOptions): Unit {
        synchronized(lock) {
            for (table in tables) {
                if (let Some(adapter) <- (table as TableAdapter)) {
                    let tableIter = adapter.newIterator()
                    iters.add(TableIterWrapper(tableIter, reverse: opt.reverse))
                }
            }
        }
    }
    
    public func getMaxVersion(): UInt64 {
        synchronized(lock) {
            var maxVer: UInt64 = 0
            for (table in tables) {
                let ver = table.getMaxVersion()
                if (ver > maxVer) {
                    maxVer = ver
                }
            }
            return maxVer
        }
    }
    
    public func getTableInfo(level: Int): ArrayList<SSTableInfo> {
        synchronized(lock) {
            let result = ArrayList<SSTableInfo>()
            for (table in tables) {
                let info = SSTableInfo(
                    id: table.getId(),
                    level: level,
                    left: table.smallest(),
                    right: table.biggest(),
                    keyCount: table.keyCount(),
                    onDiskSize: UInt32(table.size()),
                    uncompressedSize: UInt32(table.uncompressedSize()),
                    maxVersion: table.getMaxVersion()
                )
                result.add(info)
            }
            return result
        }
    }
}
