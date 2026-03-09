package badgercj.db

import std.fs.*
import std.sync.*
import std.collection.*
import badgercj.table.*
import badgercj.manifest.*
import badgercj.vlog.*

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
    private let vlog: VLogManager
    
    public init(
        opt: DBOptions,
        mt: MemTable,
        manifest: Manifest,
        lc: LevelsController,
        vlog: VLogManager
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
        this.vlog = vlog
    }
    
    public static func open(opt: DBOptions): DB {
        if (!exists(Path(opt.Dir))) {
            Directory.create(Path(opt.Dir), recursive: true)
        }
        
        let manifest = Manifest()
        let lc = LevelsController(manifest: manifest)
        let vlog = VLogManager(Path(opt.Dir))
        
        let fid = Int64(manifest.nextFileID)
        let mt = MemTable(opt, fid, false)
        
        let db = DB(opt, mt, manifest, lc, vlog)
        return db
    }
    
    public func close(): Unit {
        lock.lock()
        try {
            mt.closeWAL()
            for (immMt in imm) {
                immMt.closeWAL()
            }
            vlog.close()
            oracle.stop()
        } finally {
            lock.unlock()
        }
    }
    
    public func getMemTable(): MemTable {
        return mt
    }
    
    public func getImmMemTables(): ArrayList<MemTable> {
        return imm
    }
    
    public func getMemTables(): ArrayList<MemTable> {
        let tables = ArrayList<MemTable>()
        tables.add(mt)
        for (immMt in imm) {
            tables.add(immMt)
        }
        return tables
    }
    
    public func getLevelsController(): LevelsController {
        return lc
    }
    
    public func get(key: Array<Byte>, readTsOpt!: ?UInt64 = None): Option<ValueStruct> {
        lock.lock()
        try {
            let readTs = if (let Some(ts) <- readTsOpt) {
                ts
            } else {
                version.load()
            }
            
            let mtResult = mt.getWithTs(key, readTs)
            if (mtResult.isSome()) {
                if (let Some(vs) <- mtResult) {
                    if (!vs.isDelete()) {
                        if (vs.isValuePointer()) {
                            let vp = ValuePointer.decode(vs.value)
                            let entry = vlog.read(vp)
                            return Some(ValueStruct(entry.value, meta: 0, version: vs.version))
                        }
                        return mtResult
                    }
                }
                return None
            }
            
            for (i in 0..imm.size) {
                let immMt = imm[imm.size - 1 - i]
                let immResult = immMt.getWithTs(key, readTs)
                if (immResult.isSome()) {
                    if (let Some(vs) <- immResult) {
                        if (!vs.isDelete()) {
                            if (vs.isValuePointer()) {
                                let vp = ValuePointer.decode(vs.value)
                                let entry = vlog.read(vp)
                                return Some(ValueStruct(entry.value, meta: 0, version: vs.version))
                            }
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
                        if (vs.isValuePointer()) {
                            let vp = ValuePointer.decode(vs.value)
                            let entry = vlog.read(vp)
                            return Some(ValueStruct(entry.value, meta: 0, version: vs.version))
                        }
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
    
    // 内部方法：带 commitTs 的 set (用于 Transaction)
    public func putWithCommitTs(key: Array<Byte>, value: Array<Byte>, commitTs: UInt64): Unit {
        lock.lock()
        try {
            if (mt.shouldFlush()) {
                flushMemTableInternal()
            }
            
            // 将时间戳嵌入 key
            let keyWithTimestamp = keyWithTs(key, commitTs)
            
            let vs = if (Int64(value.size) >= opt.ValueThreshold) {
                let entry = LogEntry(key, value)
                let vp = vlog.write(entry)
                let vpBytes = vp.encode()
                ValueStruct(vpBytes, meta: Meta.bitValuePointer, version: commitTs)
            } else {
                ValueStruct(value, meta: 0, version: commitTs)
            }
            
            mt.put(keyWithTimestamp, vs)
        } finally {
            lock.unlock()
        }
    }
    
    // 内部方法：带 commitTs 的 delete (用于 Transaction)
    public func deleteWithCommitTs(key: Array<Byte>, commitTs: UInt64): Unit {
        lock.lock()
        try {
            if (mt.shouldFlush()) {
                flushMemTableInternal()
            }
            
            // 将时间戳嵌入 key
            let keyWithTimestamp = keyWithTs(key, commitTs)
            
            let vs = ValueStruct([], meta: Meta.bitDelete, version: commitTs)
            mt.put(keyWithTimestamp, vs)
        } finally {
            lock.unlock()
        }
    }
    
    public func set(key: Array<Byte>, value: Array<Byte>): Unit {
        let ts = version.fetchAdd(1)
        oracle.bumpCommitTs(ts)
        putWithCommitTs(key, value, ts)
    }
    
    public func delete(key: Array<Byte>): Unit {
        let ts = version.fetchAdd(1)
        oracle.bumpCommitTs(ts)
        deleteWithCommitTs(key, ts)
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
    
    public func newSnapshot(): Snapshot {
        return Snapshot(this)
    }
}
