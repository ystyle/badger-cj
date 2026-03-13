package badgercj.db

import badgercj.table.*
import badgercj.manifest.*
import std.collection.*
import std.fs.*
import std.io.*

public class LevelsController {
    private let levels: ArrayList<LevelHandler>
    private let manifest: Manifest
    private let dir: String
    private let nextFileID: UInt64
    private let cstatus: compactStatus
    
    public init(manifest!: Manifest = Manifest(), dir!: String = "") {
        this.manifest = manifest
        this.dir = dir
        this.nextFileID = manifest.nextFileID
        this.levels = ArrayList<LevelHandler>()
        this.cstatus = compactStatus(7)
        
        for (i in 0..7) {
            levels.add(LevelHandler(i))
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
    
    public func addTable(level: Int, table: MockTable): Unit {
        if (level < 0 || level >= levels.size) {
            return
        }
        levels[level].addTable(table)
    }
    
    public func addTable(level: Int, table: TableInterface): Unit {
        if (level < 0 || level >= levels.size) {
            return
        }
        levels[level].addTable(table)
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
            handler.appendIterators(iters, opt.reverse)
        }
    }
    
    public func loadTables(): Unit {
        for (level in 0..7) {
            let tables = manifest.levels[level]
            for (tableInfo in tables) {
                let path = sstablePath(dir, tableInfo.id)
                if (exists(Path(path))) {
                    let data = File.readFrom(Path(path))
                    let table = Table(tableInfo.id, data)
                    let adapter = TableAdapter(table)
                    levels[level].addTable(adapter)
                }
            }
        }
    }
    
    public func getMaxVersion(): UInt64 {
        var maxVer: UInt64 = 0
        for (handler in levels) {
            let ver = handler.getMaxVersion()
            if (ver > maxVer) {
                maxVer = ver
            }
        }
        return maxVer
    }
}
