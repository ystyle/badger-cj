package badgercj.manifest

import std.collection.*

/**
 * Level 中的文件信息
 */
public class TableInfo {
    public let id: UInt64
    public let size: Int64
    public let keyID: UInt64
    
    public init(id: UInt64, size!: Int64 = 0, keyID!: UInt64 = 0) {
        this.id = id
        this.size = size
        this.keyID = keyID
    }
}

/**
 * Manifest - 数据库元数据
 */
protected class Manifest {
    public var levels: ArrayList<ArrayList<TableInfo>>
    public var keyID: UInt64
    public var nextFileID: UInt64
    public var deletions: UInt64
    public var orphanedFiles: ArrayList<UInt64>
    
    public init() {
        this.levels = ArrayList<ArrayList<TableInfo>>()
        // 创建 L0-L6 共7层（与 Go BadgerDB 默认 MaxLevels 一致）
        for (_ in 0..7) {
            levels.add(ArrayList<TableInfo>())
        }
        this.keyID = 0
        this.nextFileID = 0
        this.deletions = 0
        this.orphanedFiles = ArrayList<UInt64>()
    }
    
    public func applyChanges(changes: ArrayList<ManifestChange>): Unit {
        for (change in changes) {
            applyChange(change)
        }
    }
    
    private func applyChange(change: ManifestChange): Unit {
        match (change.op) {
            case ManifestChangeOp.Create => applyCreate(change)
            case ManifestChangeOp.Delete => applyDelete(change)
            case ManifestChangeOp.DeleteAll => applyDeleteAll()
        }
    }
    
    private func applyCreate(change: ManifestChange): Unit {
        if (Int64(change.level) >= levels.size) {
            return
        }
        
        let table = TableInfo(change.id, keyID: change.keyID)
        levels[Int64(change.level)].add(table)
        
        if (change.id >= nextFileID) {
            nextFileID = change.id + 1
        }
    }
    
    private func applyDelete(change: ManifestChange): Unit {
        var levelIdx: Int64 = 0
        while (levelIdx < levels.size) {
            let found = deleteFromLevel(levelIdx, change.id)
            if (found) {
                return
            }
            levelIdx++
        }
    }
    
    private func deleteFromLevel(levelIdx: Int64, id: UInt64): Bool {
        let tables = levels[levelIdx]
        var i: Int64 = 0
        while (i < tables.size) {
            if (tables[i].id == id) {
                tables.remove(at: i)
                return true
            }
            i++
        }
        return false
    }
    
    private func applyDeleteAll(): Unit {
        var levelIdx: Int64 = 0
        while (levelIdx < levels.size) {
            levels[levelIdx].clear()
            levelIdx++
        }
    }
    
    public func getFileIDs(): ArrayList<UInt64> {
        let files = ArrayList<UInt64>()
        var levelIdx: Int64 = 0
        while (levelIdx < levels.size) {
            let tables = levels[levelIdx]
            var i: Int64 = 0
            while (i < tables.size) {
                files.add(tables[i].id)
                i++
            }
            levelIdx++
        }
        return files
    }
    
    public func clone(): Manifest {
        let m = Manifest()
        m.keyID = keyID
        m.nextFileID = nextFileID
        m.deletions = deletions
        
        var levelIdx: Int64 = 0
        while (levelIdx < levels.size) {
            let tables = levels[levelIdx]
            var i: Int64 = 0
            while (i < tables.size) {
                m.levels[levelIdx].add(tables[i])
                i++
            }
            levelIdx++
        }
        
        return m
    }
}