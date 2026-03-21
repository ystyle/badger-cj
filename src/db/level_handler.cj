package badgercj.db

import badgercj.table.*
import std.collection.*
import std.sync.*
import badgercj.utils.compareKeys

public class LevelHandler {
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
    
    public func appendIterators(iters: ArrayList<SimpleIterator>, reverse: Bool): Unit {
        synchronized(lock) {
            for (table in tables) {
                iters.add(TableInterfaceIterator(table))
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
