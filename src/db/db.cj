package badgercj.db

import std.fs.*
import std.sync.*
import std.collection.*
import badgercj.table.*
import badgercj.manifest.*

public class DB {
    private let opt: DBOptions
    private let manifest: Manifest
    private let lc: LevelsController
    private let lock: Mutex
    private var mt: MemTable
    private let imm: ArrayList<MemTable>
    private let version: AtomicUInt64
    private var nextFileID: AtomicUInt64
    public let oracle: Oracle
    
    public init(
        opt: DBOptions,
        mt: MemTable,
        manifest: Manifest,
        lc: LevelsController
    ) {
        this.opt = opt
        this.mt = mt
        this.manifest = manifest
        this.lc = lc
        this.lock = Mutex()
        this.imm = ArrayList<MemTable>()
        this.version = AtomicUInt64(1)
        this.nextFileID = AtomicUInt64(manifest.nextFileID)
        this.oracle = Oracle()
    }
    
    public static func open(opt: DBOptions): DB {
        if (!exists(Path(opt.Dir))) {
            Directory.create(Path(opt.Dir), recursive: true)
        }
        
        let manifest = Manifest()
        let lc = LevelsController(manifest: manifest)
        
        let fid = Int64(manifest.nextFileID)
        let mt = MemTable(opt, fid, false)
        
        let db = DB(opt, mt, manifest, lc)
        return db
    }
    
    public func close(): Unit {
        lock.lock()
        try {
            mt.closeWAL()
            for (immMt in imm) {
                immMt.closeWAL()
            }
            oracle.stop()
        } finally {
            lock.unlock()
        }
    }
    
    public func get(key: Array<Byte>): Option<ValueStruct> {
        lock.lock()
        try {
            let readTs = version.load()
            
            let mtResult = mt.get(key)
            if (mtResult.isSome()) {
                if (let Some(vs) <- mtResult) {
                    if (!vs.isDelete()) {
                        return mtResult
                    }
                }
                return None
            }
            
            for (i in 0..imm.size) {
                let immMt = imm[imm.size - 1 - i]
                let immResult = immMt.get(key)
                if (immResult.isSome()) {
                    if (let Some(vs) <- immResult) {
                        if (!vs.isDelete()) {
                            return immResult
                        }
                    }
                    return None
                }
            }
            
            let lcResult = lc.get(key, readTs)
            if (lcResult.isSome()) {
                if (let Some(vs) <- lcResult) {
                    if (!vs.isDelete()) {
                        return lcResult
                    }
                }
                return None
            }
            
            return None
        } finally {
            lock.unlock()
        }
    }
    
    public func set(key: Array<Byte>, value: Array<Byte>): Unit {
        lock.lock()
        try {
            if (mt.shouldFlush()) {
                flushMemTableInternal()
            }
            
            let vs = ValueStruct(value, meta: 0, version: version.fetchAdd(1))
            mt.put(key, vs)
        } finally {
            lock.unlock()
        }
    }
    
    public func delete(key: Array<Byte>): Unit {
        lock.lock()
        try {
            if (mt.shouldFlush()) {
                flushMemTableInternal()
            }
            
            let vs = ValueStruct([], meta: Meta.bitDelete, version: version.fetchAdd(1))
            mt.put(key, vs)
        } finally {
            lock.unlock()
        }
    }
    
    public func flushMemTable(): Unit {
        lock.lock()
        try {
            flushMemTableInternal()
        } finally {
            lock.unlock()
        }
    }
    
    public func getVersion(): UInt64 {
        return version.load()
    }
    
    public func newTransaction(update!: Bool = true): Transaction {
        return Transaction(this, update: update)
    }
    
    public func view<T>(fn: (Transaction) -> T): T {
        let txn = newTransaction(update: false)
        try {
            let result = fn(txn)
            txn.discard()
            return result
        } catch (e: Exception) {
            txn.discard()
            throw e
        }
    }
    
    public func update<T>(fn: (Transaction) -> T): T {
        let txn = newTransaction(update: true)
        try {
            let result = fn(txn)
            txn.commit()
            return result
        } catch (e: Exception) {
            txn.rollback()
            throw e
        }
    }
    
    private func flushMemTableInternal(): Unit {
        imm.add(mt)
        
        let fid = Int64(nextFileID.fetchAdd(1))
        mt = MemTable(opt, fid, false)
        
        let flushedMt = imm[imm.size - 1]
        flushToLevel(flushedMt)
    }
    
    private func flushToLevel(mt: MemTable): Unit {
        let entries = ArrayList<(Array<Byte>, ValueStruct)>()
        let iter = mt.iterator()
        
        while (iter.hasNext()) {
            if (let Some((key, vs)) <- iter.next()) {
                entries.add((key, vs))
            }
        }
        
        let tableID = nextFileID.fetchAdd(1)
        let table = MockTable(tableID, entries)
        
        lc.addTable(0, table)
        
        mt.decrRef()
    }
    
    public func getLevelHandler(level: Int64): LevelHandler {
        return lc.getLevelHandler(level)
    }
}
