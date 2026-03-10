package badgercj.db

import std.fs.*
import std.sync.*
import std.collection.*
import std.time.*
import badgercj.table.*
import badgercj.manifest.*
import badgercj.vlog.*
import std.collection.concurrent.*

public class DB {
    private let opt: DBOptions
    private let manifest: Manifest
    private let manifestFile: ManifestFile
    private let lc: LevelsController
    private let lock: ReadWriteLock
    private var mt: MemTable
    private let imm: ArrayList<MemTable>
    private let version: AtomicUInt64
    private var nextFileID: AtomicUInt64
    public let oracle: Oracle
    private let vlog: VLogManager
    public let writeCh: LinkedBlockingQueue<WriteRequest>
    private var running: AtomicBool
    private var flushFut: ?Future<Unit>
    
    public init(
        opt: DBOptions,
        mt: MemTable,
        manifest: Manifest,
        manifestFile: ManifestFile,
        lc: LevelsController,
        vlog: VLogManager
    ) {
        this.opt = opt
        this.mt = mt
        this.manifest = manifest
        this.manifestFile = manifestFile
        this.lc = lc
        this.lock = ReadWriteLock()
        this.imm = ArrayList<MemTable>()
        this.version = AtomicUInt64(1)
        this.nextFileID = AtomicUInt64(manifest.nextFileID)
        this.oracle = Oracle()
        this.vlog = vlog
        this.writeCh = LinkedBlockingQueue<WriteRequest>(1000)
        this.running = AtomicBool(false)
        this.flushFut = None
    }
    
    public static func open(opt: DBOptions): DB {
        if (!exists(Path(opt.Dir))) {
            Directory.create(Path(opt.Dir), recursive: true)
        }
        
        let manifestPath = Path(opt.Dir).join("MANIFEST").toString()
        let manifestFile = ManifestFile.open(manifestPath)
        let manifest = manifestFile.getManifest()
        let lc = LevelsController(manifest: manifest)
        let vlog = VLogManager(Path(opt.Dir))
        let fid = Int64(manifest.nextFileID)
        let mt = MemTable(opt, fid, false)
        
        let db = DB(opt, mt, manifest, manifestFile, lc, vlog)
        db.running = AtomicBool(true)
        let fut = spawn { db.flushLoop() }
        db.flushFut = Some(fut)
        return db
    }
    
    public func close(): Unit {
        running.store(false)
        if (let Some(fut) <- flushFut) {
            fut.get()
        }
        
        lock.writeLock.lock()
        try {
            mt.closeWAL()
            for (immMt in imm) {
                immMt.closeWAL()
            }
            vlog.close()
            oracle.stop()
        } finally {
            lock.writeLock.unlock()
        }
    }
    
    public func getMemTable(): MemTable { mt }
    public func getImmMemTables(): ArrayList<MemTable> { imm }
    
    public func getMemTables(): ArrayList<MemTable> {
        let tables = ArrayList<MemTable>()
        tables.add(mt)
        for (immMt in imm) { tables.add(immMt) }
        return tables
    }
    
    public func getLevelsController(): LevelsController { lc }
    
    public func get(key: Array<Byte>, readTsOpt!: ?UInt64 = None): Option<ValueStruct> {
        lock.readLock.lock()
        try {
            let readTs = readTsOpt ?? version.load()
            
            // Check memtable
            if (let Some(vs) <- mt.getWithTs(key, readTs)) {
                if (vs.isDelete()) { return None }
                if (vs.isValuePointer()) {
                    let vp = ValuePointer.decode(vs.value)
                    let entry = vlog.read(vp)
                    return Some(ValueStruct(entry.value, meta: 0, version: vs.version))
                }
                return Some(vs)
            }
            
            // Check immutable memtables
            for (i in 0..imm.size) {
                let immMt = imm[imm.size - 1 - i]
                if (let Some(vs) <- immMt.getWithTs(key, readTs)) {
                    if (vs.isDelete()) { return None }
                    if (vs.isValuePointer()) {
                        let vp = ValuePointer.decode(vs.value)
                        let entry = vlog.read(vp)
                        return Some(ValueStruct(entry.value, meta: 0, version: vs.version))
                    }
                    return Some(vs)
                }
            }
            
            // Check levels
            if (let Some(vs) <- lc.get(key, readTs)) {
                if (vs.isDelete()) { return None }
                if (vs.isValuePointer()) {
                    let vp = ValuePointer.decode(vs.value)
                    let entry = vlog.read(vp)
                    return Some(ValueStruct(entry.value, meta: 0, version: vs.version))
                }
                return Some(vs)
            }
            
            return None
        } finally {
            lock.readLock.unlock()
        }
    }
    
    public func set(key: Array<Byte>, value: Array<Byte>): Unit {
        let ts = version.fetchAdd(1)
        oracle.bumpCommitTs(ts)
        let req = WriteRequest(key, value, ts, isDelete: false)
        writeCh.add(req)
        req.wait()
    }
    
    public func delete(key: Array<Byte>): Unit {
        let ts = version.fetchAdd(1)
        oracle.bumpCommitTs(ts)
        let req = WriteRequest(key, [], ts, isDelete: true)
        writeCh.add(req)
        req.wait()
    }
    
    public func flushMemTable(): Unit {
        lock.writeLock.lock()
        try { flushMemTableInternal() }
        finally { lock.writeLock.unlock() }
    }
    
    public func getVersion(): UInt64 { version.load() }
    
    public func newTransaction(update!: Bool = true): Transaction {
        Transaction(this, update: update)
    }
    
    public func view<T>(fn: (Transaction) -> T): T {
        let txn = newTransaction(update: false)
        try {
            let result = fn(txn)
            txn.discard()
            result
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
            result
        } catch (e: Exception) {
            txn.rollback()
            throw e
        }
    }
    
    private func flushMemTableInternal(): Unit {
        imm.add(mt)
        let fid = Int64(nextFileID.fetchAdd(1))
        mt = MemTable(opt, fid, false)
        flushToLevel(imm[imm.size - 1])
    }
    
    private func flushToLevel(mt: MemTable): Unit {
        let entries = ArrayList<(Array<Byte>, ValueStruct)>()
        let iter = mt.iterator()
        while (iter.hasNext()) {
            if (let Some(e) <- iter.next()) { entries.add(e) }
        }
        let tableID = nextFileID.fetchAdd(1)
        lc.addTable(0, MockTable(tableID, entries))
        mt.decrRef()
    }
    
    // Simple loop: block on remove(timeout), process one request
    private func flushLoop(): Unit {
        let timeout = Duration.millisecond * 1  // Short timeout for low latency
        
        while (running.load()) {
            if (let Some(req) <- writeCh.remove(timeout)) {
                writeOneRequest(req)
            }
        }
        
        // Drain remaining
        while (writeCh.size > 0) {
            if (let Some(req) <- writeCh.tryRemove()) {
                writeOneRequest(req)
            }
        }
    }
    
    private func writeOneRequest(req: WriteRequest): Unit {
        // Write to vlog if needed
        if (UInt64(req.value.size) >= opt.ValueThreshold && !req.isDelete) {
            req.vp = Some(vlog.write(LogEntry(req.key, req.value)))
        }
        
        // Write to memtable
        lock.writeLock.lock()
        try {
            if (mt.shouldFlush()) { flushMemTableInternal() }
            
            let keyWithTs = keyWithTs(req.key, req.commitTs)
            let vs = if (req.isDelete) {
                ValueStruct([], meta: Meta.bitDelete, version: req.commitTs)
            } else if (let Some(vp) <- req.vp) {
                ValueStruct(vp.encode(), meta: Meta.bitValuePointer, version: req.commitTs)
            } else {
                ValueStruct(req.value, meta: 0, version: req.commitTs)
            }
            mt.put(keyWithTs, vs)
        } finally {
            lock.writeLock.unlock()
        }
        
        req.signal()
    }
    
    public func getLevelHandler(level: Int64): LevelHandler { lc.getLevelHandler(level) }
    public func newSnapshot(): Snapshot { Snapshot(this) }
}
