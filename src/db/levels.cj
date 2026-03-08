package badgercj.db

import badgercj.table.*
import badgercj.manifest.*
import std.collection.*

public class LevelsController {
    private let levels: ArrayList<LevelHandler>
    private let manifest: Manifest
    private let nextFileID: UInt64
    
    public init(manifest!: Manifest = Manifest()) {
        this.manifest = manifest
        this.nextFileID = manifest.nextFileID
        this.levels = ArrayList<LevelHandler>()
        
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
    
    public func getLevelHandler(level: Int): LevelHandler {
        return levels[level]
    }
    
    public func numLevels(): Int64 {
        return levels.size
    }
    
    public func getNextFileID(): UInt64 {
        return nextFileID
    }
}
