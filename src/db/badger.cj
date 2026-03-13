package badgercj.db

import std.fs.*
import std.sync.*
import std.collection.*
import std.time.*
import badgercj.table.*
import badgercj.manifest.*
import badgercj.vlog.*
import std.collection.concurrent.*

public class Badger {
    private let opt: Config
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
    public let writeCh: NotifyingWriteChannel<WriteRequest>
    private var running: AtomicBool
    private var flushFut: ?Future<Unit>
    private var compactorFut: ?Future<Unit>
    private var pipeline: ?WritePipeline
    public let reqPool: WriteRequestPool
    
    public init(
        opt: Config,
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
        this.oracle = Oracle(detectConflicts: opt.DetectConflicts)
        this.vlog = vlog
        this.writeCh = NotifyingWriteChannel<WriteRequest>(10000)
        this.running = AtomicBool(false)
        this.flushFut = None
        this.compactorFut = None
        this.pipeline = None
        this.reqPool = WriteRequestPool(maxSize: 1000)
    }
    
    public static func open(opt: Config): Badger {
        if (!exists(Path(opt.Dir))) {
            Directory.create(Path(opt.Dir), recursive: true)
        }
        
        let manifestPath = manifestPath(opt.Dir)
        let manifestFile = ManifestFile.open(manifestPath)
        let manifest = manifestFile.getManifest()
        
        let lc = LevelsController(manifest: manifest, dir: opt.Dir)
        lc.loadTables()
        
        let fid = Int64(manifest.nextFileID)
        let mt = MemTable(opt, fid, true)
        
        let vlog = VLogManager(Path(opt.Dir))
        let db = Badger(opt, mt, manifest, manifestFile, lc, vlog)
        
        var recoveredVersion = mt.getMaxVersion()
        let lcVersion = lc.getMaxVersion()
        if (lcVersion > recoveredVersion) {
            recoveredVersion = lcVersion
        }
        
        if (recoveredVersion > 0) {
            db.version.store(recoveredVersion + 1)
        }
        
        db.running = AtomicBool(true)
        db.pipeline = Some(WritePipeline({ reqs => db.writeRequests(reqs) }, queueSize: 1000))
        let fut = spawn { db.flushLoop() }
        db.flushFut = Some(fut)
        db.startCompactor()
        return db
    }
    
    public func close(): Unit {
        running.store(false)
        writeCh.close()  // Wake up blocking remove()
        if (let Some(p) <- pipeline) {
            p.close()
        }
        if (let Some(fut) <- flushFut) {
            fut.get()
        }
        if (let Some(fut) <- compactorFut) {
            fut.get()
        }
        
        lock.writeLock.lock()
        try {
            if (!mt.isEmpty()) {
                let changes = flushMemTableToDisk(mt)
                manifestFile.saveChanges(changes)
            }
            
            for (immMt in imm) {
                let changes = flushMemTableToDisk(immMt)
                manifestFile.saveChanges(changes)
            }
            imm.clear()
            
            mt.deleteWAL()
            
            vlog.close()
            oracle.stop()
            manifestFile.close()
        } finally {
            lock.writeLock.unlock()
        }
    }
    
    private func flushMemTableToDisk(mt: MemTable): ManifestChangeSet {
        let builder = TableBuilder()
        let iter = mt.iterator()
        while (iter.hasNext()) {
            if (let Some(e) <- iter.next()) {
                let (key, vs) = e
                builder.add(key, vs)
            }
        }
        let data = builder.finish()
        
        let tableID = nextFileID.fetchAdd(1)
        let path = sstablePath(opt.Dir, tableID)
        let f = File(Path(path), Write)
        f.write(data)
        f.close()
        
        let table = Table(tableID, data)
        lc.addTable(0, TableAdapter(table))
        
        let changes = ManifestChangeSet()
        changes.add(ManifestChange(tableID, ManifestChangeOp.Create, level: 0))
        return changes
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
        let req = reqPool.get(ts)
        req.addEntry(key, value, isDelete: false)
        writeCh.add(req)
        req.wait()
        reqPool.put(req)
    }
    
    public func delete(key: Array<Byte>): Unit {
        let ts = version.fetchAdd(1)
        oracle.bumpCommitTs(ts)
        let req = reqPool.get(ts)
        req.addEntry(key, [], isDelete: true)
        writeCh.add(req)
        req.wait()
        reqPool.put(req)
    }
    
    public func flushMemTable(): Unit {
        lock.writeLock.lock()
        try { flushMemTableInternal() }
        finally { lock.writeLock.unlock() }
    }
    
    public func getVersion(): UInt64 { version.load() }
    
    public func flushWAL(): Unit {
        mt.flushWAL()
    }
    
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
    
// Collect requests and emit to pipeline
    private func flushLoop(): Unit {
        while (running.load()) {
            if (let Some(req) <- writeCh.remove()) {
                let reqs = ArrayList<WriteRequest>()
                reqs.add(req)
                
                // Batch collect more requests (non-blocking)
                while (reqs.size < 1000) {
                    if (let Some(r) <- writeCh.tryRemove()) {
                        reqs.add(r)
                    } else {
                        break
                    }
                }
                
                // Emit to pipeline (async)
                if (let Some(p) <- pipeline) {
                    p.emit(reqs)
                }
            }
        }
        
        // Drain remaining
        while (writeCh.size() > 0) {
            if (let Some(req) <- writeCh.tryRemove()) {
                writeOneRequest(req)
            }
        }
    }
    
    private func writeRequests(reqs: ArrayList<WriteRequest>): Unit {
        if (reqs.isEmpty()) {
            return
        }
        
        for (req in reqs) {
            let entries = req.getEntries()
            
            // Check if we need to flush (under lock)
            lock.writeLock.lock()
            if (mt.shouldFlush()) { flushMemTableInternal() }
            lock.writeLock.unlock()
            
            // Write to memtable (no lock needed - skiplist is thread-safe)
            for (entry in entries) {
                let vpOpt: Option<ValuePointer> = if (UInt64(entry.value.size) >= opt.ValueThreshold && !entry.isDelete) {
                    Some(vlog.write(LogEntry(entry.key, entry.value)))
                } else {
                    None
                }
                
                let keyWithTs = keyWithTs(entry.key, req.commitTs)
                let vs = if (entry.isDelete) {
                    ValueStruct([], meta: Meta.bitDelete, version: req.commitTs)
                } else if (let Some(vp) <- vpOpt) {
                    ValueStruct(vp.encode(), meta: Meta.bitValuePointer, version: req.commitTs)
                } else {
                    ValueStruct(entry.value, meta: 0, version: req.commitTs)
                }
                mt.put(keyWithTs, vs)
            }
        }
        
        for (req in reqs) {
            req.done()
        }
    }
    
    private func writeOneRequest(req: WriteRequest): Unit {
        // Check if we need to flush (under lock)
        lock.writeLock.lock()
        if (mt.shouldFlush()) { flushMemTableInternal() }
        lock.writeLock.unlock()
        
        // Write to memtable (no lock needed - skiplist is thread-safe)
        for (entry in req.getEntries()) {
            let vpOpt: Option<ValuePointer> = if (UInt64(entry.value.size) >= opt.ValueThreshold && !entry.isDelete) {
                Some(vlog.write(LogEntry(entry.key, entry.value)))
            } else {
                None
            }
            
            let keyWithTs = keyWithTs(entry.key, req.commitTs)
            let vs = if (entry.isDelete) {
                ValueStruct([], meta: Meta.bitDelete, version: req.commitTs)
            } else if (let Some(vp) <- vpOpt) {
                ValueStruct(vp.encode(), meta: Meta.bitValuePointer, version: req.commitTs)
            } else {
                ValueStruct(entry.value, meta: 0, version: req.commitTs)
            }
            mt.put(keyWithTs, vs)
        }
        
        req.done()
    }
    
    private func startCompactor(): Unit {
        let fut = spawn {
            let compaction = Compaction(this)
            var gcCounter = 0
            while (running.load()) {
                sleep(Duration.millisecond * 100)
                compaction.runCompaction()
                
                gcCounter++
                if (gcCounter >= 600) {
                    vlog.runGC(0.5)
                    gcCounter = 0
                }
            }
        }
        compactorFut = Some(fut)
    }
    
    public func runVLogGC(discardRatio: Float64): Bool {
        vlog.runGC(discardRatio)
    }
    
    public func compact(): Unit {
        let compaction = Compaction(this)
        while (true) {
            let prio = compaction.pickCompaction()
            if (prio.isNone()) {
                break
            }
            if (!compaction.runCompaction()) {
                break
            }
        }
    }
    
    public func getLevelHandler(level: Int64): LevelHandler { lc.getLevelHandler(level) }
    public func newSnapshot(): Snapshot { Snapshot(this) }
    public func getOpt(): Config { opt }
    public func getCompactStatus(): compactStatus { lc.getCompactStatus() }
}
