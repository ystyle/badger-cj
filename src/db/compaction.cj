package badgercj.db

import std.sync.*
import badgercj.table.*

public class Compaction {
    private let db: Badger
    private let lock: Mutex
    
    public init(db: Badger) {
        this.db = db
        this.lock = Mutex()
    }
    
    public func runCompaction(): Unit {
        lock.lock()
        try {
            if (!shouldCompact()) {
                return
            }
            
            let cdef = pickCompaction()
            if (cdef.isNone()) {
                return
            }
            
            if (let Some(def) <- cdef) {
                doCompact(def)
            }
        } finally {
            lock.unlock()
        }
    }
    
    private func shouldCompact(): Bool {
        let l0Handler = db.getLevelHandler(0)
        return l0Handler.numTables() > 2
    }
    
    private func pickCompaction(): Option<CompactionDef> {
        let l0Handler = db.getLevelHandler(0)
        let numTables = l0Handler.numTables()
        
        if (numTables == 0) {
            return None
        }
        
        return Some(CompactionDef(0))
    }
    
    private func doCompact(cdef: CompactionDef): Unit {
        let l0Handler = db.getLevelHandler(0)
        let l1Handler = db.getLevelHandler(1)
        
        let tables = l0Handler.getTables()
        if (tables.size == 0) {
            return
        }
        
        for (table in tables) {
            l1Handler.addTable(table)
        }
        
        l0Handler.clearTables()
    }
}

struct CompactionDef {
    public let level: Int64
    
    public init(level: Int64) {
        this.level = level
    }
}
