package badgercj.db

import std.fs.*
import std.sync.*
import std.collection.*
import std.time.*
import std.io.*
import std.convert.Parsable
import std.env.atExit
import badgercj.table.*
import badgercj.manifest.*
import badgercj.vlog.*
import badgercj.io_uring.*
import badgercj.utils.{compareKeys, hasPrefix}
import std.collection.concurrent.*

private let MetaTxn: Byte = 0x02
private let MetaFinTxn: Byte = 0x04
private let TxnKey: Array<Byte> = [0x21, 0x62, 0x61, 0x64, 0x67, 0x65, 0x72, 0x21, 0x74, 0x78, 0x6e]

public class Badger <: VLogGCDB {
    private let opt: Config
    private let manifest: Manifest
    private let manifestFile: ManifestFile
    private let lc: LevelsController
    private let lock: ReadWriteLock
    private var mt: MemTable
    private let imm: ArrayList<MemTable>
    private let version: AtomicUInt64
    private var nextFileID: AtomicUInt64
    protected let oracle: Oracle
    private let vlog: VLogManager
    protected let writeCh: NotifyingWriteChannel<WriteRequest>
    private var running: AtomicBool
    private var flushFut: ?Future<Unit>
    private var compactorFut: ?Future<Unit>
    private var pipeline: ?WritePipeline
    protected let reqPool: WriteRequestPool
    
    protected init(
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
        // InMemory 模式验证
        if (opt.InMemory && opt.Dir != "") {
            throw BadgerException.invalidConfig("Cannot use InMemory mode with Dir set")
        }
        
        // 创建目录（非 InMemory 模式）
        if (!opt.InMemory && !exists(Path(opt.Dir))) {
            Directory.create(Path(opt.Dir), recursive: true)
        }
        
        // MANIFEST
        var manifestFile: ManifestFile
        if (opt.InMemory) {
            manifestFile = ManifestFile.memory()
        } else {
            manifestFile = ManifestFile.open(manifestPath(opt.Dir))
        }
        let manifest = manifestFile.getManifest()
        
        // LevelsController
        let lc = LevelsController(manifest: manifest, dir: opt.Dir, inMemory: opt.InMemory)
        if (!opt.InMemory) {
            lc.loadTables()
        }
        
        // 回收已有的 WAL 文件（.mem 文件）
        var immTables = ArrayList<MemTable>()
        var maxVersion: UInt64 = 0
        
        if (!opt.InMemory && !opt.DisableWAL) {
            let memFiles = listMemFiles(opt.Dir)
            for (memFid in memFiles) {
                let memPath = "${opt.Dir}/${memFid}.mem"
                if (exists(Path(memPath))) {
                    let wal = WAL.open(memPath)
                    let replayMt = MemTable(opt, memFid, false)
                    wal.replay(replayMt)
                    let mtVersion = replayMt.getMaxVersion()
                    if (mtVersion > maxVersion) {
                        maxVersion = mtVersion
                    }
                    if (!replayMt.isEmpty()) {
                        immTables.add(replayMt)
                    }
                }
            }
        }
        
        let fid = Int64(manifest.nextFileID)
        let mt = MemTable(opt, fid, !opt.InMemory)
        
        // VLog（InMemory 模式不需要）
        var vlog: VLogManager
        if (opt.InMemory) {
            vlog = VLogManager()
        } else {
            vlog = VLogManager(Path(opt.Dir))
        }
        let db = Badger(opt, mt, manifest, manifestFile, lc, vlog)
        
        // 添加 replay 的 imm tables
        for (immMt in immTables) {
            db.imm.add(immMt)
        }
        
        if (!opt.InMemory) {
            vlog.setDB(db, discardChecker: { key, vs => discardEntry(key, vs) })
        }
        
        var recoveredVersion = mt.getMaxVersion()
        if (maxVersion > recoveredVersion) {
            recoveredVersion = maxVersion
        }
        let lcVersion = lc.getMaxVersion()
        if (lcVersion > recoveredVersion) {
            recoveredVersion = lcVersion
        }
        
        if (recoveredVersion > 0) {
            db.version.store(recoveredVersion + 1)
            db.oracle.initTs(recoveredVersion + 1)
        }
        
        db.running = AtomicBool(true)
        db.pipeline = Some(WritePipeline({ reqs => db.writeRequests(reqs) }, queueSize: 1000))
        let fut = spawn { db.flushLoop() }
        db.flushFut = Some(fut)
        db.startCompactor()
        
        // 注册进程退出时自动关闭
        if (opt.AutoCloseOnExit) {
            atExit() {
                db.close()
            }
        }
        
        return db
    }
    
    public func close(): Unit {
        // 幂等检查：如果已经关闭则直接返回
        if (!running.compareAndSwap(true, false)) {
            return
        }
        
        writeCh.close()
        if (let Some(p) <- pipeline) {
            p.close()
        }
        if (let Some(fut) <- flushFut) {
            fut.get()
        }
        if (let Some(fut) <- compactorFut) {
            fut.get()
        }
        
        // InMemory 模式：跳过持久化操作
        if (opt.InMemory) {
            oracle.stop()
            return
        }
        
        lock.writeLock.lock()
        try {
            let allTables = ArrayList<MemTable>()
            if (!mt.isEmpty()) {
                allTables.add(mt)
            }
            for (immMt in imm) {
                allTables.add(immMt)
            }
            
            if (allTables.size > 1 && opt.UseIoUring) {
                flushMemTablesBatch(allTables)
            } else {
                for (t in allTables) {
                    let changes = flushMemTableToDisk(t)
                    manifestFile.saveChanges(changes)
                }
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
    
    private func flushMemTablesBatch(tables: ArrayList<MemTable>): Unit {
        let requests = ArrayList<FileWriteRequest>()
        let tableDataList = ArrayList<(UInt64, Array<Byte>)>()
        
        for (t in tables) {
            let builder = TableBuilder(bloomFalsePositive: opt.BloomFalsePositive, compression: opt.Compression)
            let iter = t.iterator()
            while (iter.hasNext()) {
                if (let Some(e) <- iter.next()) {
                    let (key, vs) = e
                    builder.add(key, vs)
                }
            }
            let data = builder.finish()
            
            let tableID = nextFileID.fetchAdd(1)
            tableDataList.add((tableID, data))
            
            // 非 InMemory 模式才写文件
            if (!opt.InMemory) {
                let path = sstablePath(opt.Dir, tableID)
                requests.add(FileWriteRequest(path, data))
            }
        }
        
        if (!opt.InMemory) {
            writeFilesBatch(requests, useIoUring: true)
        }
        
        for ((tableID, data) in tableDataList) {
            if (opt.InMemory) {
                lc.addMemoryTable(tableID, data)
            } else {
                let table = Table(tableID, data)
                lc.addTable(0, TableAdapter(table))
            }
            
            let changes = ManifestChangeSet()
            changes.add(ManifestChange(tableID, ManifestChangeOp.Create, level: 0))
            manifestFile.saveChanges(changes)
        }
    }
    
    private func flushMemTableToDisk(mt: MemTable): ManifestChangeSet {
        let builder = TableBuilder(bloomFalsePositive: opt.BloomFalsePositive, compression: opt.Compression)
        let iter = mt.iterator()
        while (iter.hasNext()) {
            if (let Some(e) <- iter.next()) {
                let (key, vs) = e
                builder.add(key, vs)
            }
        }
        let data = builder.finish()
        
        let tableID = nextFileID.fetchAdd(1)
        
        // InMemory 模式不写文件
        if (!opt.InMemory) {
            let path = sstablePath(opt.Dir, tableID)
            writeFile(path, data, useIoUring: opt.UseIoUring)
        }
        
        if (opt.InMemory) {
            lc.addMemoryTable(tableID, data)
        } else {
            let table = Table(tableID, data)
            lc.addTable(0, TableAdapter(table))
        }
        
        let changes = ManifestChangeSet()
        changes.add(ManifestChange(tableID, ManifestChangeOp.Create, level: 0))
        return changes
    }
    
    protected func getMemTable(): MemTable { mt }
    protected func getImmMemTables(): ArrayList<MemTable> { imm }
    
    protected func getMemTables(): ArrayList<MemTable> {
        let tables = ArrayList<MemTable>()
        tables.add(mt)
        for (immMt in imm) { tables.add(immMt) }
        return tables
    }
    
    protected func getLevelsController(): LevelsController { lc }
    protected func getManifestFile(): ManifestFile { manifestFile }
    
    public func get(key: Array<Byte>, readTsOpt!: ?UInt64 = None): Option<ValueStruct> {
        lock.readLock.lock()
        try {
            let readTs = readTsOpt ?? oracle.currentTs()
            
            // Check memtable
            if (let Some(vs) <- mt.getWithTs(key, readTs)) {
                if (isDeletedOrExpired(vs.meta, vs.expiresAt)) { return None }
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
                    if (isDeletedOrExpired(vs.meta, vs.expiresAt)) { return None }
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
                if (isDeletedOrExpired(vs.meta, vs.expiresAt)) { return None }
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
    
    public func batchSet(entries: ArrayList<Entry>): Unit {
        if (entries.isEmpty()) {
            return
        }
        let ts = version.fetchAdd(1)
        oracle.bumpCommitTs(ts)
        let req = reqPool.get(ts)
        for (e in entries) {
            req.addEntry(e.key, e.value, isDelete: e.isDelete(), meta: e.meta, userMeta: e.userMeta, expiresAt: e.expiresAt)
        }
        writeCh.add(req)
        req.wait()
        reqPool.put(req)
    }
    
    public func batchSetAsync(entries: ArrayList<Entry>, callback: ?(Unit) -> Unit): Unit {
        if (entries.isEmpty()) {
            return
        }
        let ts = version.fetchAdd(1)
        oracle.bumpCommitTs(ts)
        let req = reqPool.get(ts)
        for (e in entries) {
            req.addEntry(e.key, e.value, isDelete: e.isDelete(), meta: e.meta, userMeta: e.userMeta, expiresAt: e.expiresAt)
        }
        writeCh.add(req)
        
        let cb = callback
        spawn {
            req.wait()
            reqPool.put(req)
            if (let Some(fn) <- cb) {
                fn(())
            }
        }
    }
    
    public func flushMemTable(): Unit {
        lock.writeLock.lock()
        try { flushMemTableInternal() }
        finally { lock.writeLock.unlock() }
    }
    
    protected func getVersion(): UInt64 { version.load() }
    
    protected func flushWAL(): Unit {
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
        let builder = TableBuilder(bloomFalsePositive: opt.BloomFalsePositive, compression: opt.Compression)
        let iter = mt.iterator()
        while (iter.hasNext()) {
            if (let Some((key, vs)) <- iter.next()) {
                builder.add(key, vs)
            }
        }
        
        let data = builder.finish()
        if (data.size == 0) {
            mt.decrRef()
            return
        }
        
        let tableID = nextFileID.fetchAdd(1)
        let table = Table(tableID, data)
        lc.addTable(0, TableAdapter(table))
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
            
            lock.writeLock.lock()
            if (mt.shouldFlush()) { flushMemTableInternal() }
            lock.writeLock.unlock()
            
            for (entry in entries) {
                let vpOpt: Option<ValuePointer> = if (UInt64(entry.value.size) >= opt.ValueThreshold && !entry.isDelete) {
                    Some(vlog.write(LogEntry(entry.key, entry.value, meta: entry.userMeta, expiresAt: entry.expiresAt)))
                } else {
                    None
                }
                
                let keyWithTs = keyWithTs(entry.key, req.commitTs)
                let vs = if (entry.isDelete) {
                    ValueStruct([], meta: Meta.bitDelete, version: req.commitTs)
                } else if (let Some(vp) <- vpOpt) {
                    let combinedMeta = Meta.bitValuePointer | entry.meta
                    ValueStruct(vp.encode(), meta: combinedMeta, 
                                userMeta: entry.userMeta, expiresAt: entry.expiresAt, version: req.commitTs)
                } else {
                    ValueStruct(entry.value, meta: entry.meta, 
                                userMeta: entry.userMeta, expiresAt: entry.expiresAt, version: req.commitTs)
                }
                mt.put(keyWithTs, vs)
            }
        }
        
        for (req in reqs) {
            req.done()
        }
    }
    
    private func writeOneRequest(req: WriteRequest): Unit {
        lock.writeLock.lock()
        if (mt.shouldFlush()) { flushMemTableInternal() }
        lock.writeLock.unlock()
        
        for (entry in req.getEntries()) {
            let vpOpt: Option<ValuePointer> = if (UInt64(entry.value.size) >= opt.ValueThreshold && !entry.isDelete) {
                Some(vlog.write(LogEntry(entry.key, entry.value, meta: entry.userMeta, expiresAt: entry.expiresAt)))
            } else {
                None
            }
            
            let keyWithTs = keyWithTs(entry.key, req.commitTs)
            let vs = if (entry.isDelete) {
                ValueStruct([], meta: Meta.bitDelete, version: req.commitTs)
            } else if (let Some(vp) <- vpOpt) {
                let combinedMeta = Meta.bitValuePointer | entry.meta
                ValueStruct(vp.encode(), meta: combinedMeta, 
                            userMeta: entry.userMeta, expiresAt: entry.expiresAt, version: req.commitTs)
            } else {
                ValueStruct(entry.value, meta: entry.meta, 
                            userMeta: entry.userMeta, expiresAt: entry.expiresAt, version: req.commitTs)
            }
            mt.put(keyWithTs, vs)
        }
        
        req.done()
    }
    
    private func startCompactor(): Unit {
        // InMemory 模式不需要 Compaction
        if (opt.InMemory) {
            return
        }
        
        let fut = spawn {
            let compaction = Compaction(this)
            var gcCounter = 0
            while (running.load()) {
                // 使用较短的超时检查，以便更快响应关闭信号
                var i = 0
                while (i < 10 && running.load()) {
                    sleep(Duration.millisecond * 10)
                    i++
                }
                if (!running.load()) {
                    break
                }
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
        // InMemory 模式不需要 VLog GC
        if (opt.InMemory) {
            return false
        }
        vlog.runGC(discardRatio)
    }
    
    public func compact(): Unit {
        // InMemory 模式不需要 Compaction
        if (opt.InMemory) {
            return
        }
        
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
    
    protected func getLevelHandler(level: Int64): LevelHandler { lc.getLevelHandler(level) }
    public func newSnapshot(): Snapshot { Snapshot(this) }
    protected func getOpt(): Config { opt }
    protected func getCompactStatus(): compactStatus { lc.getCompactStatus() }
    
    public func getVS(key: Array<Byte>): ?ValueStruct {
        lock.readLock.lock()
        try {
            let readTs = version.load()
            
            if (let Some(vs) <- mt.getWithTs(key, readTs)) {
                return Some(vs)
            }
            
            for (i in 0..imm.size) {
                let immMt = imm[imm.size - 1 - i]
                if (let Some(vs) <- immMt.getWithTs(key, readTs)) {
                    return Some(vs)
                }
            }
            
            if (let Some(vs) <- lc.get(key, readTs)) {
                return Some(vs)
            }
            
            return None
        } finally {
            lock.readLock.unlock()
        }
    }
    
    public func setRaw(key: Array<Byte>, value: Array<Byte>, meta: Byte, version: UInt64, expiresAt: UInt64): Unit {
        let keyWithTs = keyWithTs(key, version)
        let vs = ValueStruct(value, meta: meta, version: version, expiresAt: expiresAt)
        mt.put(keyWithTs, vs)
    }
    
    public func getValueThreshold(): UInt64 { opt.ValueThreshold }
    
    public func isClosed(): Bool {
        !running.load()
    }
    
    public func sync(): Unit {
        lock.readLock.lock()
        try {
            mt.flushWAL()
            for (immMt in imm) {
                immMt.flushWAL()
            }
            vlog.sync()
        } finally {
            lock.readLock.unlock()
        }
    }
    
    public func size(): DBSize {
        var lsmSize: Int64 = 0
        for (level in 0..lc.numLevels()) {
            lsmSize += lc.getLevelHandler(level).totalSize()
        }
        
        let vlogSize = Int64(vlog.size())
        return DBSize(lsm: lsmSize, vlog: vlogSize)
    }
    
    public func tables(): ArrayList<SSTableInfo> {
        lc.getTableInfo()
    }
    
    public func levels(): ArrayList<LevelInfo> {
        lc.getLevelInfo()
    }
    
    protected func ranges(prefix: Array<Byte>, numRanges: Int64): ArrayList<KeyRange> {
        var splits = ArrayList<Array<Byte>>()
        let tables = this.tables()
        
        let maxLevel = Int64(opt.MaxLevels) - 1
        for (ti in tables) {
            if (ti.Level != maxLevel) {
                continue
            }
            let userKey = parseKey(ti.Right)
            if (hasPrefix(userKey, prefix)) {
                splits.add(userKey)
            }
        }
        
        if (splits.size < 32) {
            let numTables = if (tables.size == 0) { 1 } else { tables.size }
            var numPerTable = 32 / numTables
            if (numPerTable == 0) {
                numPerTable = 1
            }
            let lcSplits = lc.keySplits(numPerTable, prefix)
            for (s in lcSplits) {
                let userKey = parseKey(s)
                splits.add(userKey)
            }
        }
        
        if (splits.size < 32) {
            let maxPerSplit: Int64 = 10000
            
            lock.readLock.lock()
            try {
                for (immMt in imm) {
                    collectMtSplits(immMt, prefix, maxPerSplit, splits)
                }
                collectMtSplits(mt, prefix, maxPerSplit, splits)
            } finally {
                lock.readLock.unlock()
            }
        }
        
        sortByteArrays(splits)
        
        var ranges = ArrayList<KeyRange>()
        var start: Array<Byte> = []
        for (key in splits) {
            ranges.add(KeyRange(start, key, true))
            start = key.clone()
        }
        ranges.add(KeyRange(start, [], false))
        
        var totalSize: Int64 = 0
        for (ti in tables) {
            let tr = KeyRange(parseKey(ti.Left), parseKey(ti.Right), true)
            for (r in ranges) {
                if ((r.left.size == 0 || r.right.size == 0)) {
                    continue
                }
                if (overlapsWith(r, tr)) {
                    r.size += Int64(ti.UncompressedSize)
                }
            }
        }
        
        for (r in ranges) {
            totalSize += r.size
        }
        
        if (totalSize == 0) {
            return ranges
        }
        
        let avg = totalSize / numRanges
        
        var out = ArrayList<KeyRange>()
        var i: Int64 = 0
        while (i < ranges.size) {
            let r = ranges[i]
            let cur = KeyRange(r.left, r.right, r.right.size > 0)
            cur.size = r.size
            i++
            while (i < ranges.size) {
                let next = ranges[i]
                if (cur.size + next.size > avg) {
                    break
                }
                cur.right = next.right
                cur.hasRight = next.right.size > 0
                cur.size += next.size
                i++
            }
            out.add(cur)
        }
        
        out
    }
    
    private func sortByteArrays(arr: ArrayList<Array<Byte>>): Unit {
        for (i in 0..arr.size) {
            for (j in i + 1..arr.size) {
                if (compareKeys(arr[i], arr[j]) > 0) {
                    let tmp = arr[i]
                    arr[i] = arr[j]
                    arr[j] = tmp
                }
            }
        }
    }
    
    private func overlapsWith(r1: KeyRange, r2: KeyRange): Bool {
        if (r1.right.size == 0 || r2.left.size == 0) {
            return true
        }
        if (r2.right.size == 0 || r1.left.size == 0) {
            return true
        }
        compareKeys(r1.left, r2.right) < 0 && compareKeys(r2.left, r1.right) < 0
    }
    
    private func collectMtSplits(mt: MemTable, prefix: Array<Byte>, maxPerSplit: Int64, splits: ArrayList<Array<Byte>>): Unit {
        if (mt.isEmpty()) {
            return
        }
        var count: Int64 = 0
        let iter = mt.iterator()
        while (iter.hasNext()) {
            if (let Some((keyWithTs, _)) <- iter.next()) {
                if (count % maxPerSplit == 0) {
                    let userKey = parseKey(keyWithTs)
                    if (hasPrefix(userKey, prefix)) {
                        splits.add(userKey)
                    }
                }
                count++
            }
        }
    }
    
    public func Backup(writer: OutputStream, since!: UInt64 = 0): UInt64 {
        let backupWriter = BackupWriter(this, writer)
        
        let stream = Stream(this)
        stream.sinceTs = since
        
        stream.keyToList = { key: Array<Byte>, iter: Iterator =>
            let list = ArrayList<StreamKV>()
            
            while (iter.valid()) {
                let item = iter.item()
                
                if (compareKeys(item.key, key) != 0) {
                    break
                }
                
                if (item.version < since) {
                    iter.next()
                    continue
                }
                
                if (item.isDeletedOrExpired()) {
                    iter.next()
                    continue
                }
                
                let val = item.valueCopy()
                
                let meta: Byte = item.meta & (!(MetaTxn | MetaFinTxn | Meta.bitValuePointer))
                
                list.add(StreamKV(
                    key: item.keyCopy(),
                    value: val,
                    userMeta: item.userMeta,
                    version: item.version,
                    expiresAt: item.expiresAt,
                    meta: meta
                ))
                
                if (item.discardEarlierVersions()) {
                    list.add(StreamKV(
                        key: item.keyCopy(),
                        value: [],
                        userMeta: 0,
                        version: item.version - 1,
                        expiresAt: 0,
                        meta: Meta.bitDelete
                    ))
                    break
                }
                
                iter.next()
            }
            
            list
        }
        
        stream.send = { kvs: ArrayList<StreamKV> =>
            for (kv in kvs) {
                backupWriter.addKV(kv)
            }
        }
        
        stream.orchestrate()
        
        return backupWriter.finish()
    }
    
    public func Restore(reader: InputStream): Unit {
        let backupReader = BackupReader(this, reader)
        backupReader.restore()
    }
    
    protected func updateNextTs(ts: UInt64): Unit {
        if (ts >= oracle.nextTs()) {
            oracle.bumpCommitTs(ts + 1)
        }
    }
    
    protected func doneRestore(): Unit {
        let nextTs = oracle.nextTs()
        oracle.doneUntil(nextTs - 1)
        
        // 确保 Restore 的数据持久化到 WAL
        if (!opt.InMemory && !opt.DisableWAL) {
            mt.flushWAL()
        }
    }
}

// 列出目录中所有 .mem 文件的 ID（按升序排序）
private func listMemFiles(dir: String): ArrayList<Int64> {
    let result = ArrayList<Int64>()
    let path = Path(dir)
    
    if (!exists(path)) {
        return result
    }
    
    try {
        let entries = Directory.readFrom(path)
        for (entry in entries) {
            let name = entry.name
            if (name.endsWith(".mem")) {
                let idStr = name[0..(name.size - 4)]
                match (Int64.tryParse(idStr)) {
                    case Some(id) => result.add(id)
                    case None => ()
                }
            }
        }
    } catch (e: Exception) {
        // 忽略读取目录失败
    }
    
    // 按升序排序
    sortIds(result)
    result
}

private func sortIds(ids: ArrayList<Int64>): Unit {
    let arr = ids.toArray()
    var i = 0
    while (i < arr.size - 1) {
        var j = i + 1
        while (j < arr.size) {
            if (arr[i] > arr[j]) {
                let tmp = arr[i]
                arr[i] = arr[j]
                arr[j] = tmp
            }
            j += 1
        }
        i += 1
    }
    ids.clear()
    for (id in arr) {
        ids.add(id)
    }
}
