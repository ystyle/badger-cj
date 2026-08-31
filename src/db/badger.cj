package badgercj.db

import std.fs.*
import std.sync.*
import std.collection.*
import std.time.*
import std.io.*
import std.convert.Parsable
import std.env.{atExit, exit}
// 优雅退出（SIGINT/SIGTERM → close）依赖 std.runtime 信号 API，仅 Linux 编译
// （官方文档标注"不支持 Windows"；macOS 如需支持可放宽为 os != "Windows"）
@When[os == "Linux"]
import std.runtime.*
import badgercj.table.*
import badgercj.manifest.*
import badgercj.vlog.*
import badgercj.io_uring.*
import badgercj.utils.{compareKeys, hasPrefix}
import std.collection.concurrent.*

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
    protected let writeCh: CloseableBlockingQueue<WriteRequest>
    private var running: AtomicBool
    private var flushFut: ?Future<Unit>
    private var compactorFut: ?Future<Unit>
    private var pipeline: ?WritePipeline
    protected let reqPool: WriteRequestPool
    // —— 优雅退出（docker stop / Ctrl+C）——
    // registerSignalShutdown() 注册后，SIGINT/SIGTERM 置 shutdownSignal，
    // 后台 shutdownLoop 轮询到后执行 close()（信号上下文仅做 lock-free 置位，安全）
    private var signalShutdownRegistered: Bool = false
    private let shutdownSignal: AtomicBool = AtomicBool(false)
    @When[os == "Linux"]
    private var signalHandler: ?((Int32) -> Bool) = None
    @When[os == "Linux"]
    private var signalShutdownFut: ?Future<Unit> = None
    // 优雅关闭钩子：registerShutdownHook() 注册的附加清理回调，信号优雅关闭时在
    // shutdownLoop（后台线程）中、close() 之前按注册顺序依次执行（信号上下文安全）。
    private let shutdownHooks: ArrayList<() -> Unit> = ArrayList<() -> Unit>()
    private let shutdownHooksLock: Mutex = Mutex()
    
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
        this.writeCh = CloseableBlockingQueue<WriteRequest>(10000)
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
                    let replayMt = MemTable(opt, memFid, true)
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
        
        // 注销信号 handler（若注册过优雅退出），close 后信号不再触发 close
        cleanupSignalHandler()
        
        // 1. 先关闭写入通道
        writeCh.close()
        
        // 2. 等待 flushLoop 处理完 writeCh 中的请求
        if (let Some(fut) <- flushFut) {
            fut.get()
        }
        
        // 3. 关闭 pipeline（处理完队列中的请求）
        if (let Some(p) <- pipeline) {
            p.close()
        }
        
        // 4. 等待 compactor 结束
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
    
    // 注册优雅退出：SIGINT/SIGTERM（docker stop / Ctrl+C / kill 默认信号）→ 关闭数据库。
    // 与 AutoCloseOnExit（仅正常退出路径）互补——容器场景 atExit 不触发，靠这里兜底。
    // handler 内只做 lock-free 置位（信号上下文安全），真正的 close() 由后台线程执行，
    // 不阻塞信号处理线程；exitAfterClose=true（默认）时 close 后退出进程（docker stop 语义）。
    // 条件编译：std.runtime 信号 API 官方标注不支持 Windows，非 Linux 平台为 no-op。
    @When[os == "Linux"]
    public func registerSignalShutdown(exitAfterClose!: Bool = true): Unit {
        if (signalShutdownRegistered) {
            return
        }
        signalShutdownRegistered = true
        
        let handler: (Int32) -> Bool = { _ =>
            shutdownSignal.store(true)
            true  // 必须返回 true：阻止信号默认行为（实测返回 false 会触发默认终止，进程来不及 close）
        }
        signalHandler = Some(handler)
        registerSignalHandler(Signal.SIGINT, handler)
        registerSignalHandler(Signal.SIGTERM, handler)
        
        signalShutdownFut = Some(spawn { shutdownLoop(exitAfterClose) })
    }
    
    // 注册优雅关闭钩子：SIGINT/SIGTERM 触发优雅关闭时，在 close()（flush memtable 落盘）
    // 之前按注册顺序依次执行。适用宿主进程与数据库一起收尾的资源（关服务 / 停写入等）。
    //
    // 与「宿主自注册信号 handler」两种模式可并存：
    //   A. 宿主先 registerSignalHandler 注册自己的 handler（返回 false 继续分发）→ 再
    //      registerSignalShutdown()：FIFO 下两者都执行（badger 的 handler 返回 true 阻止
    //      默认终止行为，必须放最后）；
    //   B. 宿主把清理逻辑经本 API 注册进 badger：单一监听者、无注册顺序依赖（推荐）。
    //
    // 注意：钩子仅在 registerSignalShutdown() 的信号关闭路径执行，不随普通 close() 触发；
    // 钩子在后台线程执行（非信号上下文），可安全调用 db 操作（此时尚未 close）。
    public func registerShutdownHook(cb: () -> Unit): Unit {
        shutdownHooksLock.lock()
        try {
            shutdownHooks.add(cb)
        } finally {
            shutdownHooksLock.unlock()
        }
    }
    
    // 按注册顺序执行优雅关闭钩子（持锁只取快照，用户代码在锁外执行）
    private func runShutdownHooks(): Unit {
        let hooks = ArrayList<() -> Unit>()
        shutdownHooksLock.lock()
        try {
            for (h in shutdownHooks) {
                hooks.add(h)
            }
        } finally {
            shutdownHooksLock.unlock()
        }
        for (h in hooks) {
            h()
        }
    }
    
    @When[os != "Linux"]
    public func registerSignalShutdown(exitAfterClose!: Bool = true): Unit {
        // 非 Linux 平台 no-op（std.runtime 信号 API 不可用；macOS 如需支持可放宽为 os != "Windows"）
    }
    
    @When[os == "Linux"]
    private func shutdownLoop(exitAfterClose: Bool): Unit {
        while (running.load() && !shutdownSignal.load()) {
            sleep(Duration.millisecond * 50)
        }
        if (shutdownSignal.load()) {
            println("[badger] received SIGINT/SIGTERM, closing gracefully...")
            // 先执行宿主清理钩子（后台线程，非信号上下文），再 close 落盘
            runShutdownHooks()
            close()
            if (exitAfterClose) {
                exit(0)
            }
        }
    }
    
    // 注销信号 handler（close 时调用，幂等；非 Linux 为空实现）
    @When[os == "Linux"]
    private func cleanupSignalHandler(): Unit {
        if (let Some(handler) <- signalHandler) {
            unregisterSignalHandler(Signal.SIGINT, handler)
            unregisterSignalHandler(Signal.SIGTERM, handler)
            signalHandler = None
        }
    }
    
    @When[os != "Linux"]
    private func cleanupSignalHandler(): Unit {}
    
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
                // 跳过事务结束标记（bitFinTxn）
                if (vs.isFinTxn()) {
                    continue
                }
                // 清除 bitTxn 标记（已提交的事务条目）
                let cleanVs = vs.clearTxnMarks()
                builder.add(key, cleanVs)
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
        if (let Some(msg) <- req.errorOf()) {
            // 失败必报（评审 P1-2）：batchSet 同样不能"假装成功"
            reqPool.put(req)
            throw Exception(msg)
        }
        reqPool.put(req)
    }
    
    // 批量异步写入：callback 收到 ?String——None 表示成功，Some(msg) 表示写入失败原因。
    // 失败必报（评审 P1-2）：错误经 callback 上报而非静默；未提供 callback 时日志兜底。
    public func batchSetAsync(entries: ArrayList<Entry>, callback!: ?((?String) -> Unit) = None): Unit {
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
            let errMsg = req.errorOf()
            if (let Some(msg) <- errMsg) {
                if (let Some(fn) <- cb) {
                    fn(Some(msg))
                } else {
                    println("[badger] batchSetAsync write failed: ${msg}")
                }
            } else if (let Some(fn) <- cb) {
                fn(None)
            }
            reqPool.put(req)
        }
    }
    
    public func flushMemTable(): Unit {
        lock.writeLock.lock()
        try { flushMemTableInternal() }
        finally { lock.writeLock.unlock() }
    }
    
    protected func getVersion(): UInt64 { version.load() }
    internal func getTxnKey(): Array<Byte> { TxnKey }
    
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
    
    public func update<T>(fn: (Transaction) -> T): TxnResult<T> {
        let txn = newTransaction(update: true)
        var userResult: Option<T> = None
        try {
            userResult = Some(fn(txn))
        } catch (e: Exception) {
            txn.rollback()
            return TxnResult.Error(e.message)
        }
        
        match (txn.commit()) {
            case TxnStatus.Ok => 
                TxnResult.Success(userResult.getOrThrow())
            case TxnStatus.Conflict => 
                TxnResult.Conflict
            case TxnStatus.Error(msg) => 
                TxnResult.Error(msg)
        }
    }
    
    public func updateOrThrow<T>(fn: (Transaction) -> T): T {
        match (update(fn)) {
            case TxnResult.Success(v) => v
            case TxnResult.Conflict => throw TxnConflict()
            case TxnResult.Error(msg) => throw Exception(msg)
        }
    }
    
    private func flushMemTableInternal(): Unit {
        imm.add(mt)
        let fid = Int64(nextFileID.fetchAdd(1))
        mt = MemTable(opt, fid, false)
        // 设计约束（评审 P2-2 评估结论）：flushToLevel 在写锁内同步构建 SSTable 并
        // addTable 到 L0，同时该表仍保留在 imm——刚写入数据始终可从内存（imm）读到。
        // 若改为"后台线程构建+写盘+从 imm 移除"：① 刚写入数据的读取将从内存变磁盘
        // （L0 磁盘表，无 block cache），读性能回退；② close 的 imm 写盘联动需同步
        // 重构，属架构级改动。收益（写锁时长）与风险（读性能/数据正确性）不成比例，
        // 且默认 memTableSize(64MB) 下 flush 不频繁、锁内构建毫秒级，影响可控。
        // 异步化列为未来优化项。
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
    
    // 阶段 1（锁外）：vlog 写入所有大值条目，构建 (keyWithTs, vs) 待写入列表。
    // vlog.write 是无缓冲 File.write（每次 syscall），必须移出全局写锁
    // （评审 P2-2）——否则整批持锁期间所有读线程被磁盘 I/O 阻塞。
    private func prepareEntries(entries: ArrayList<WriteEntry>, commitTs: UInt64): ArrayList<(Array<Byte>, ValueStruct)> {
        let prepared = ArrayList<(Array<Byte>, ValueStruct)>()
        for (entry in entries) {
            let vpOpt: Option<ValuePointer> = if (UInt64(entry.value.size) >= opt.ValueThreshold && !entry.isDelete) {
                Some(vlog.write(LogEntry(entry.key, entry.value, meta: entry.userMeta, expiresAt: entry.expiresAt)))
            } else {
                None
            }
            
            let keyWithTs = keyWithTs(entry.key, commitTs)
            let vs = if (entry.isDelete) {
                ValueStruct([], meta: Meta.bitDelete, version: commitTs)
            } else if (let Some(vp) <- vpOpt) {
                let combinedMeta = Meta.bitValuePointer | entry.meta
                ValueStruct(vp.encode(), meta: combinedMeta, 
                            userMeta: entry.userMeta, expiresAt: entry.expiresAt, version: commitTs)
            } else {
                ValueStruct(entry.value, meta: entry.meta, 
                            userMeta: entry.userMeta, expiresAt: entry.expiresAt, version: commitTs)
            }
            prepared.add((keyWithTs, vs))
        }
        return prepared
    }
    
    // 阶段 2（锁内）：flush 检查 + mt.put。持写锁保证 mt.put 与 flush（imm 交换）
    // 期间读锁互斥，避免读线程在 put/flush 中途读到不一致的 memtable 集合。
    private func putPrepared(prepared: ArrayList<(Array<Byte>, ValueStruct)>): Unit {
        lock.writeLock.lock()
        try {
            for ((keyWithTs, vs) in prepared) {
                // 条目级检查：单 req 可含大量条目（如批量物化），若只检查一次，
                // arena 会在条目循环中耗尽而抛异常（对齐 badger-go ensureRoomForWrite 语义）
                if (mt.shouldFlush()) { flushMemTableInternal() }
                mt.put(keyWithTs, vs)
            }
        } finally {
            lock.writeLock.unlock()
        }
    }
    
    private func writeRequests(reqs: ArrayList<WriteRequest>): Unit {
        if (reqs.isEmpty()) {
            return
        }
        
        // vlog I/O 锁外（prepare）→ 锁内 put（putPrepared）；异常由 runBatch 统一
        // markFailed + done（pipeline 路径）
        for (req in reqs) {
            let prepared = prepareEntries(req.getEntries(), req.commitTs)
            putPrepared(prepared)
        }
        
        for (req in reqs) {
            req.done()
        }
    }
    
    private func writeOneRequest(req: WriteRequest): Unit {
        // drain 路径（flushLoop 关闭时）直接调用，无 runBatch 包装——
        // 自身必须 try/catch/finally：失败 markFailed（评审 P2-1，此前静默成功），
        // done() 放 finally 保证 wait() 不悬挂
        try {
            let prepared = prepareEntries(req.getEntries(), req.commitTs)
            putPrepared(prepared)
        } catch (e: Exception) {
            req.markFailed(e.message)
        } catch (e: Error) {
            req.markFailed("runtime error while writing request")
        } finally {
            req.done()
        }
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
    
    /**
     * scan - 创建支持 for-in 的迭代器
     * 
     * 用法：
     * ```cangjie
     * for (item in db.scan("user_".toArray())) {
     *     println(item.key())
     * }
     * ```
     */
    public func scan(prefix: Array<Byte>, reverse!: Bool = false, allVersions!: Bool = false): PrefixIterable {
        PrefixIterable(this, prefix, reverse: reverse, allVersions: allVersions)
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
                
                let meta: Byte = item.meta & (!(Meta.bitTxn | Meta.bitFinTxn | Meta.bitValuePointer))
                
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
