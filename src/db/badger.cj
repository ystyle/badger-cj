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

// —— key/value 大小上限（对齐 badger-go）——
// go：key > 65000 写前拒绝（txn.go maxKeySize——表/vlog 格式 key 长度字段为 UInt16，
// cut 到 65000 留出内部前缀与 8 字节 ts 后缀余量）；value 无 64KB 限制，由
// ValueThreshold 决定内联或进 vlog，且不得超过 vlog 文件大小（go ValueLogFileSize
// 1<<30-1）。cj 侧 memtable value 槽已扩为 UInt32，内联条目不再有 64KB 编码限制。
private let MaxKeySize: Int64 = 65000
private let MaxValueSize: UInt64 = (1u64 << 30) - 1

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
    // —— 异步 flusher（flush 移出写锁，对齐 badger-go flushChan + flushMemtable）——
    // 写路径/公开 API 在写锁内只做 memtable 轮换（imm.add + 新表），轮换出的表经
    // flushQueue 交给 flusher 协程在锁外构建 SSTable + 落盘 + MANIFEST + addTable，
    // 完成后回到写锁内短临界区出队 decrRef。imm 集合变更（add/remove）始终持写锁，
    // 与读路径（读锁内遍历 imm）的互斥不变量不变。
    private let flushQueue: CloseableBlockingQueue<MemTable>
    // imm 深度的原子镜像（imm ArrayList 由写锁保护，等待水位判断需要在锁外读）
    private let immCount: AtomicInt64
    // flusher 腾位/完成通知（等待方均须在写锁外 wait，避免死锁）
    private let flushCondMutex: Mutex
    private let flushCond: Condition
    private var flusherFut: ?Future<Unit>
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
        this.flushQueue = CloseableBlockingQueue<MemTable>(Int64(opt.NumMemtables))
        this.immCount = AtomicInt64(0)
        this.flushCondMutex = Mutex()
        synchronized(this.flushCondMutex) {
            this.flushCond = this.flushCondMutex.condition()
        }
        this.flusherFut = None
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
        
        // LevelsController（构造时已按 manifest 加载磁盘表；此处不再重复 loadTables，
        // 避免 R2：每张表双份驻留内存）
        let lc = LevelsController(manifest: manifest, dir: opt.Dir, inMemory: opt.InMemory,
            mmapSSTable: opt.MmapSSTable)
        
        // 回收已有的 WAL 文件（.mem 文件）
        var immTables = ArrayList<MemTable>()
        var maxVersion: UInt64 = 0
        var maxMemFid: Int64 = -1
        
        if (!opt.InMemory && !opt.DisableWAL) {
            let memFiles = listMemFiles(opt.Dir)
            for (memFid in memFiles) {
                if (memFid > maxMemFid) {
                    maxMemFid = memFid
                }
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
        
        // 当前 memtable 的 WAL fid 必须大于所有现存 .mem（遗留文件将被 replay 后立即
        // flush 删除，其 fid 不能被复用——否则 flush 的 WAL 删除会误删新 memtable 文件）
        let fid = if (maxMemFid >= Int64(manifest.nextFileID)) {
            maxMemFid + 1
        } else {
            Int64(manifest.nextFileID)
        }
        let mt = MemTable(opt, fid, !opt.InMemory)
        
        // VLog（InMemory 模式不需要）
        var vlog: VLogManager
        if (opt.InMemory) {
            vlog = VLogManager()
        } else {
            // Config.MmapVLog 控制段写路径（mmap 稀疏预分配 vs 无缓冲 File.write）
            var vlogOpt = VLogOptions()
            vlogOpt.useMmap = opt.MmapVLog
            vlog = VLogManager(Path(opt.Dir), opt: vlogOpt)
        }
        let db = Badger(opt, mt, manifest, manifestFile, lc, vlog)
        // 当前 memtable 已占用 fid（未走 reserve），把文件序列推进到该 fid 之后——
        // 否则首次 flush 会 reserve 到同一 id，新 memtable 的 WAL 被 flush 旧表的
        // decrRef 误删（崩溃窗口丢未 flush 数据）。
        db.seedFileIDAfter(fid)
        
        // 添加 replay 的 imm tables
        for (immMt in immTables) {
            db.imm.add(immMt)
            db.immCount.fetchAdd(1)
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
        
        // 对齐 badger-go（db.go:353 "Flush them to disk asap"）：open 恢复出的遗留
        // imm（崩溃前已切出但未落盘的 memtable）立即 flush 落盘，数据不再悬在内存
        // 等 close。失败则 open 抛错（表保留在 imm、WAL 未删，重开重放可重试），
        // 不留半落盘状态。此阶段 flusher 尚未启动，走同步 flush 路径。
        while (!db.imm.isEmpty()) {
            db.flushMemTableSync(db.imm[0])
        }
        
        db.running = AtomicBool(true)
        db.pipeline = Some(WritePipeline({ reqs => db.writeRequests(reqs) }, queueSize: 1000))
        let fut = spawn { db.flushLoop() }
        db.flushFut = Some(fut)
        db.startCompactor()
        db.startFlusher()
        
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
        
        // 3.5. 停止 flusher（对齐 go flusher drain 语义）：关队列唤醒阻塞的 remove，
        // flusher 把队列中剩余表处理完（成功落盘的完成 imm 出队）后退出。必须放在
        // 拿写锁之前 join——flusher 的完成段（imm 出队）需要写锁，先拿锁再 join 即
        // 死锁。flusher 关闭期间重试失败而放弃的表留在 imm/队列，由下方锁内兜底
        // flush（数据不丢；失败上抛语义与旧 close 一致）。
        flushQueue.close()
        if (let Some(f) <- flusherFut) {
            f.get()
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
                for (t in allTables) {
                    // 落盘成功即释放：decrRef 删除该表 WAL（不残留 .mem → 下次 open
                    // 不会 replay 出重复数据）
                    t.decrRef()
                }
            } else {
                for (t in allTables) {
                    let changes = flushMemTableToDisk(t)
                    manifestFile.saveChanges(changes)
                    t.decrRef()
                }
            }
            imm.clear()
            // 兜底 flush 已处理全部在途表：镜像计数归零并唤醒（可能仍在水位等待的
            // flushMemTable 调用者；其等待循环同时检查 running，close 后即退出）
            immCount.store(0)
            synchronized(flushCondMutex) {
                flushCond.notifyAll()
            }
            
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
        // 逐个隔离：**宿主钩子抛异常绝不能吃掉落盘**。
        // 实测（cjreg）：它的钩子做 cjxtApp.stop()（停 HTTP/WS 时抛 SocketException），
        // 旧实现让异常从 shutdownLoop 逃出去 → 下面的 close()（flush 全部 memtable）
        // 根本没跑 → 容器等不到落盘被 SIGKILL → 最近写入全丢。
        // 钩子只是"顺手收尾"，失败也不能影响本库最关键的落盘动作。
        for (h in hooks) {
            try {
                h()
            } catch (e: Exception) {
                println("[badger] shutdown hook failed (ignored, close/flush continues): " + e.toString())
            }
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
                    // 与单表路径 flushMemTableToDisk 对齐：跳过事务结束标记、清除事务标记
                    if (vs.isFinTxn()) {
                        continue
                    }
                    let cleanVs = vs.clearTxnMarks()
                    builder.add(key, cleanVs)
                }
            }
            let data = builder.finish()
            
            let tableID = reserveFileID()
            tableDataList.add((tableID, data))
            
            // 非 InMemory 模式才写文件
            if (!opt.InMemory) {
                let path = sstablePath(opt.Dir, tableID)
                requests.add(FileWriteRequest(path, data))
            }
        }
        
        if (!opt.InMemory) {
            // 写盘结果全量检查（修复：此前完全忽略返回值，io_uring 失败/缺结果静默丢数据）
            let results = writeFilesBatch(requests, useIoUring: true)
            if (results.size != requests.size) {
                throw Exception("flushMemTablesBatch: write results incomplete " +
                    "(got ${results.size}, want ${requests.size})")
            }
            for (r in results) {
                if (!r.success) {
                    let errMsg = match (r.error) {
                        case Some(msg) => msg
                        case None => "unknown error"
                    }
                    throw Exception("flushMemTablesBatch write failed: ${r.path}: ${errMsg}")
                }
            }
        }
        
        for ((tableID, data) in tableDataList) {
            if (opt.InMemory) {
                lc.addMemoryTable(tableID, data)
            } else {
                // 已落盘：表数据改用只读映射（构建产物 data 至此可弃，不再常驻 GC 堆）
                let path = sstablePath(opt.Dir, tableID)
                let table = if (opt.MmapSSTable) {
                    Table(tableID, tableData: MmapTableData(path))
                } else {
                    Table(tableID, data)
                }
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
        
        let tableID = reserveFileID()
        
        // InMemory 模式不写文件
        if (!opt.InMemory) {
            let path = sstablePath(opt.Dir, tableID)
            // 写失败由 writeFile 抛异常（返回值恒为 data.size，无独立检查意义）
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
        // 同步语义（对齐 badger-go / 旧 flushMemTableInternal）：返回时当前 memtable
        // 已落盘（含 MANIFEST + imm 出队，数据不再悬在内存）。实现 = 写锁内轮换入队
        // → 锁外交给 flusher → 等待该表完成标志（flusher 串行 FIFO，本表完成时队列
        // 中更早的表必然已全部落盘）。
        // 空表分支：当前 mt 无数据不可轮换，但仍须等待此前已轮换（在途）的表全部
        // 落盘——旧同步实现 flush 后 imm 恒空，调用方（含测试/宿主）依赖
        // 「flushMemTable 返回 = 无在途表」的约定（skiplist node 高度随机导致
        // arena 占用波动，最后一轮写入可能恰好整轮轮换完 → mt 为空但队列非空）。
        while (true) {
            var oldOpt: ?MemTable = None
            var needRoom = false
            var emptyMt = false
            lock.writeLock.lock()
            try {
                if (mt.isEmpty()) {
                    emptyMt = true
                } else if (immCount.load() >= Int64(opt.NumMemtables)) {
                    // 背压：imm 已满，锁外等待（不能持写锁等 flusher——死锁）
                    needRoom = true
                } else {
                    // 轮换 + 入队同锁段原子（见 rotateAndEnqueueLocked）
                    oldOpt = Some(rotateAndEnqueueLocked())
                }
            } finally {
                lock.writeLock.unlock()
            }
            if (emptyMt) {
                // 无可轮换数据：等在途表全部落盘出队后返回
                awaitFlusherIdle()
                return
            }
            if (needRoom) {
                waitForFlushRoom()
                continue
            }
            let old = oldOpt.getOrThrow()
            waitMemTableFlushed(old)
            return
        }
    }
    
    // 供测试观测：imm 在途深度（immCount 原子镜像）
    internal func getImmCount(): Int64 {
        immCount.load()
    }
    
    protected func getVersion(): UInt64 { version.load() }
    
    // 文件 id 分配统一出口（对齐 badger-go levelsController.reserveFileID）：
    // 运行期 flush / close / compaction / WAL fid 必须出自同一序列，避免 id 重叠覆写。
    protected func reserveFileID(): UInt64 {
        nextFileID.fetchAdd(1)
    }
    
    // open 用：当前 memtable 的 fid 未经 reserve 直读 manifest.nextFileID，
    // 把序列推进到该 fid 之后，保证后续 reserve 不与现存文件/WAL 撞 id。
    internal func seedFileIDAfter(fid: Int64): Unit {
        if (Int64(nextFileID.load()) <= fid) {
            nextFileID.store(UInt64(fid + 1))
        }
    }
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
    
    // ==================== 异步 flusher（flush 移出写锁，对齐 badger-go flushChan 机制）===
    // 锁模型不变量（与旧 flushToLevel 全程持写锁相比，安全模型不扩大）：
    //   ① imm 集合的 add/remove 必须在 db 写锁内——读路径（get/getVS/ranges 等）在
    //      读锁内遍历 imm，二者互斥关系保持不变；
    //   ② 表「逻辑出队」（读不可见）只发生在落盘 + MANIFEST + addTable 之后，不存在
    //      「已从 imm 摘除但新表不可读」的窗口；
    //   ③ 持 db 写锁期间绝不等待 flusher（flusher 完成段需要写锁，持锁等待即死锁）；
    //      背压/水位等待一律先释放写锁。
    // 运行期结构：写路径 / flushMemTable() 在写锁内做「轮换 + 入队」（rotateAndEnqueue
    // Locked，两动作同锁段原子）→ 单 flusher 协程锁外 persistMemTable（构建 +
    // 写盘 + MANIFEST + 挂内存 L0）→ 完成后回写锁内 dequeueFlushed 出队释放。
    // 失败语义（对齐 go handleMemTableFlush 无限重试）：表保留 imm/WAL，重试不丢数据；
    // close 中放弃重试，由 close 锁内兜底 flush（失败上抛 = 旧 close 语义）。
    
    // [写锁内] 轮换 + 入队（原子）：当前 mt → imm 尾并新建空 mt（reserve 新 fid/WAL），
    // 被轮换表在**同一锁段内**入 flushQueue。
    // 原子性与异常安全的关键：
    //   ① 所有可能抛错的步骤（reserve + 新 MemTable 构造：arena 2×memTableSize 分配、
    //      WAL 建文件）**先于任何状态变更**执行——OOM/IO 失败时本函数零变更，调用方
    //      （写路径）下一轮自然重试 rotate，无孤儿表；
    //   ② 状态变更序列（imm.add + immCount++ + mt 切换 + 入队）不再含大分配——消除
    //      「表已入 imm 却未入队」的滞留窗口（高负载 OOM 下复现的整批数据丢失根因，
    //      修复前 rotate 与入队两段式 + 新表构造夹在中间均产生过该窗口）；
    //   ③ 锁内 add 不会阻塞：rotate 前调用方已检查 immCount < NumMemtables，而队列
    //      元素数 ≤ immCount - flusher 手中表数 < 容量——数学上必有空位；即便个别
    //      时刻队列满，flusher 的 remove 不依赖 db 写锁，腾位后 add 返回，无死锁。
    // 返回被轮换表（供调用方等待其完成标志）。
    private func rotateAndEnqueueLocked(): MemTable {
        // 阶段 1（可抛）：新表构造完成前不触碰任何共享状态
        let fid = Int64(reserveFileID())
        let newMt = MemTable(opt, fid, false)
        // 阶段 2（不可抛的引用移动 + 入队）：同锁段原子完成
        let old = mt
        imm.add(old)
        immCount.fetchAdd(1)
        mt = newMt
        flushQueue.add(old)
        old
    }
    
    // [锁外] 把一张 memtable 构建为 L0 SSTable：迭代 → TableBuilder → finish → 落盘
    // （io_uring 失败自动降级同步写）→ MANIFEST saveChanges（先记录后可见，对齐 go
    // addLevel0Table）→ 挂内存 L0。成功返回后数据已持久且可读，调用方随后出队释放。
    // 空表（无条目）直接返回：不建表不落盘（与旧实现落盘空表相比的行为修正——空表
    // 无数据可持久，imm 出队由调用方统一完成）。
    // 失败抛异常：表保持 imm/WAL 状态不变（重试 / close / 下次 open 兜底恢复）。
    private func persistMemTable(mt: MemTable): Unit {
        let builder = TableBuilder(bloomFalsePositive: opt.BloomFalsePositive, compression: opt.Compression)
        let iter = mt.iterator()
        while (iter.hasNext()) {
            if (let Some((key, vs)) <- iter.next()) {
                // 与 close 路径 flushMemTableToDisk 对齐：跳过事务结束标记、清除事务标记
                if (vs.isFinTxn()) {
                    continue
                }
                let cleanVs = vs.clearTxnMarks()
                builder.add(key, cleanVs)
            }
        }
        
        let data = builder.finish()
        if (data.size == 0) {
            // 空表无数据可落盘（出队 + decrRef 由调用方统一做，WAL 无内容删除安全）
            return
        }
        
        let tableID = reserveFileID()
        
        if (!opt.InMemory) {
            let path = sstablePath(opt.Dir, tableID)
            // 写失败（磁盘满/IO 错）由 writeFile 抛异常；io_uring 不可用已自动降级同步写
            writeFile(path, data, useIoUring: opt.UseIoUring)
            
            let changes = ManifestChangeSet()
            changes.add(ManifestChange(tableID, ManifestChangeOp.Create, level: 0))
            manifestFile.saveChanges(changes)
        }
        
        if (opt.InMemory) {
            lc.addMemoryTable(tableID, data)
        } else {
            let table = Table(tableID, data)
            lc.addTable(0, TableAdapter(table))
        }
    }
    
    // [应持写锁（或 open 恢复期单线程）] 出队：从 imm 按 fid 定位移除 + decrRef（删
    // WAL——数据唯一持久副本已在盘上）+ 计数减一 + 唤醒水位等待者。
    // 按 fid 定位而非假定队首：轮换入队与 flusher 处理顺序可解耦（并发 flushMemTable
    // 与写路径轮换可能交错入队，但写锁保证 remove 与读遍历互斥）。
    private func dequeueFlushed(mt: MemTable): Unit {
        var idx = -1
        for (i in 0..imm.size) {
            if (imm[i].getFid() == mt.getFid()) {
                idx = i
                break
            }
        }
        if (idx < 0) {
            throw Exception("async flush: memtable fid=${mt.getFid()} not found in imm (double dequeue?)")
        }
        imm.remove(at: idx)
        immCount.fetchSub(1)
        mt.decrRef()
        // 完成标志必须在 decrRef（删 WAL）之后置位：等待方（flushMemTable）据此
        // 认为"本表已持久可读且不再悬在内存"
        mt.markFlushDone()
        synchronized(flushCondMutex) {
            flushCond.notifyAll()
        }
    }
    
    // 同步 flush 一张 imm 表（open 恢复期专用：flusher 未启动、无并发读写）。
    // 语义与异步路径一致：persist → 出队。失败抛（open 中止，表保留 imm/WAL，
    // 重开重放可重试——不留半落盘状态）。
    private func flushMemTableSync(mt: MemTable): Unit {
        persistMemTable(mt)
        dequeueFlushed(mt)
    }
    
    // 启动单 flusher 协程（open 末尾调用；close 中 join 停止）
    private func startFlusher(): Unit {
        let fut = spawn { flusherLoop() }
        flusherFut = Some(fut)
    }
    
    // flusher 主循环：串行取表处理（对齐 go flushMemtable 单 goroutine）。
    // 循环存活条件 = running 或队列仍有表（close 后 drain 阶段继续工作）。
    // 队列层系统级错误（Error）只记录不退出——一次 OOM 不能杀死 flusher，
    // 否则写路径背压（flushQueue.add 阻塞）永久停顿 = 重演生产挂起事故
    // （WritePipeline.loop 同款 Error 边界，b19a030）。
    private func flusherLoop(): Unit {
        while (running.load() || flushQueue.size() > 0) {
            var table: ?MemTable = None
            try {
                table = flushQueue.remove()
            } catch (e: Error) {
                println("[badger] flusher queue system error: ${e.message}")
                continue
            }
            if (let Some(mt) <- table) {
                flushWithRetry(mt)
            }
        }
    }
    
    // 单表落盘 + 出队，失败重试：
    //   - Exception（磁盘/IO/编码）：running 中 sleep 1s 重试（表保留 imm/WAL 不丢，
    //     对齐 go flushMemtable 的"error flushing memtable, retrying"）；close 中
    //     （!running）放弃重试，表留给 close 锁内兜底 flush（失败由 close 上抛）。
    //   - Error（OOM 等系统级）：不吞协程，同策略记录后重试/放弃——错误可见且链路存活。
    private func flushWithRetry(mt: MemTable): Unit {
        while (true) {
            try {
                persistMemTable(mt)
                lock.writeLock.lock()
                try {
                    dequeueFlushed(mt)
                } finally {
                    lock.writeLock.unlock()
                }
                return
            } catch (e: Exception) {
                if (!running.load()) {
                    println("[badger] flusher: abandon flush during close: ${e.message}")
                    return
                }
                println("[badger] flusher: flush failed, retrying in 1s: ${e.message}")
                sleep(Duration.second)
            } catch (e: Error) {
                if (!running.load()) {
                    println("[badger] flusher: abandon flush during close (system error): ${e.message}")
                    return
                }
                println("[badger] flusher: flush system error, retrying in 1s: ${e.message}")
                sleep(Duration.second)
            }
        }
    }
    
    // [锁外] 等待 flusher 腾出空间（immCount 降到 NumMemtables 之下）或 db 停止。
    // 供写路径 / flushMemTable 在检测到背压后调用——必须在未持 db 写锁时执行。
    private func waitForFlushRoom(): Unit {
        synchronized(flushCondMutex) {
            while (immCount.load() >= Int64(opt.NumMemtables) && running.load()) {
                flushCond.wait()
            }
        }
    }
    
    // [锁外] 等待特定 memtable 完成异步 flush（flushMemTable 同步语义）。
    // flusher 串行 FIFO：本表完成 ⇒ 队列中更早的表已全部落盘。db 停止（close）时
    // 退出（close 兜底 flush 保证数据仍落盘或上抛）。
    private func waitMemTableFlushed(mt: MemTable): Unit {
        synchronized(flushCondMutex) {
            while (!mt.isFlushDone() && running.load()) {
                flushCond.wait()
            }
        }
    }
    
    // [锁外] 等待所有已轮换（入队）的 memtable 完成落盘出队；不动当前 mt。
    // 供崩溃恢复类测试模拟「进程静止」（真实 kill -9 时 flusher 随进程终止，磁盘
    // 状态即崩溃点状态，无需等待）——同进程不 close 直接重开前调用，避免后台
    // flusher 仍在写盘/删 WAL 与第二个实例互踩目录。
    internal func awaitFlusherIdle(): Unit {
        synchronized(flushCondMutex) {
            while (immCount.load() > 0 && running.load()) {
                flushCond.wait()
            }
        }
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
            // 大小校验（对齐 badger-go Txn.Set 的写前拒绝，在 vlog 写入与 WAL 之前）：
            // ① key > 65000 直接拒绝——若延迟到 flush 建表才暴露，会以 UInt16 窄化系统级
            //    异常（Error）炸掉写路径（与 OOM 杀协程同模式），且数据滞留 imm 无法落盘
            // ② value > vlog 单文件容量拒绝（go exceedsSize("Value", ValueLogFileSize)）
            if (entry.key.size > MaxKeySize) {
                throw Exception("Key too big, maximum allowed size is ${MaxKeySize} bytes, got ${entry.key.size}")
            }
            if (UInt64(entry.value.size) > MaxValueSize) {
                throw Exception("Value too big, maximum allowed size is ${MaxValueSize} bytes, got ${entry.value.size}")
            }
            
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
    
    // 阶段 2：flush 检查 + mt.put。持写锁保证 mt.put 与 imm 轮换/出队期间与读路径
    // （读锁遍历 imm）互斥；单条目的锁段极短（无磁盘 I/O），flush 构建/写盘已移出
    // 写锁由 flusher 执行——写路径不再被 flush 的磁盘 I/O 整批阻塞。
    private func putPrepared(prepared: ArrayList<(Array<Byte>, ValueStruct)>): Unit {
        for ((keyWithTs, vs) in prepared) {
            putOneWithFlush(keyWithTs, vs)
        }
    }
    
    // 单条目原子段（对齐 badger-go ensureRoomForWrite 语义的条目级版）：
    //   - 条目级检查：单 req 可含大量条目（如批量物化），若只检查一次，arena 会在
    //     条目循环中耗尽而抛异常；
    //   - mt 满 → 写锁内「轮换 + 入队」原子完成（rotateAndEnqueueLocked）——即便
    //     随后本条 put 抛异常（OOM 等 Error），旧表已入队，其数据必被 flusher 落盘
    //     （不丢已成功写入的数据；本条失败由 runBatch markFailed 上报）；
    //   - imm 深度已达 NumMemtables（背压）→ 释放写锁等 flusher 腾位后重试——
    //     持写锁等待 flusher 即死锁（flusher 完成段需要写锁）。
    private func putOneWithFlush(keyWithTs: Array<Byte>, vs: ValueStruct): Unit {
        while (true) {
            var needRoomWait = false
            lock.writeLock.lock()
            try {
                if (mt.shouldFlush()) {
                    if (immCount.load() >= Int64(opt.NumMemtables)) {
                        needRoomWait = true
                    } else {
                        rotateAndEnqueueLocked()
                    }
                }
                if (!needRoomWait) {
                    mt.put(keyWithTs, vs)
                }
            } finally {
                lock.writeLock.unlock()
            }
            if (needRoomWait) {
                // 背压：等 flusher 出队腾位（flusher 存活由 Error 边界保证，见
                // flusherLoop）；等待期间读者不受影响（写锁已释放）
                waitForFlushRoom()
                continue
            }
            return
        }
    }
    
    private func writeRequests(reqs: ArrayList<WriteRequest>): Unit {
        if (reqs.isEmpty()) {
            return
        }
        
        // vlog I/O 锁外（prepare）→ 锁内 put（putPrepared）；异常与完成信号统一由
        // runBatch 处理（pipeline 路径）——此处**不得**再 done()：完成计数多减一次会让
        // wait() 提前唤醒，调用方随即把请求归还对象池，另一线程取出后 reset() 清空
        // entries，而 runBatch 的 finally 仍在遍历同一请求 → ConcurrentModificationException
        // （表现为偶发写入失败）。
        for (req in reqs) {
            let prepared = prepareEntries(req.getEntries(), req.commitTs)
            putPrepared(prepared)
        }
    }
    
    private func writeOneRequest(req: WriteRequest): Unit {
        // drain 路径（flushLoop 关闭时）直接调用，无 runBatch 包装——
        // 自身必须 try/catch/finally：失败 markFailed（评审 P2-1，此前静默成功），
        // done() 放 finally 保证 wait() 不悬挂；Error 不捕获（系统级错误自然传播）。
        try {
            let prepared = prepareEntries(req.getEntries(), req.commitTs)
            putPrepared(prepared)
        } catch (e: Exception) {
            req.markFailed(failureMsg(e))
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
                // 单轮 compaction 失败（写盘/IO 错）不杀死 compactor 协程：
                // 记录后继续下一轮（对齐 badger-go compactor 错误容忍语义），
                // 否则一次磁盘错误 = compaction 永久停止 = L0 无限堆积。
                // 系统级 Error（OOM 等）同策略（与 flusherLoop/WritePipeline.loop
                // 同款存活性边界）：compactor 死亡 = L0 永不压缩 = 内存/磁盘无限堆积。
                try {
                    compaction.runCompaction()
                } catch (e: Exception) {
                    println("[badger] compaction error: ${e.message}")
                } catch (e: Error) {
                    println("[badger] compaction system error: ${e.message}")
                }
                
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
        // 忽略读取目录失败（不阻塞打开），但必须告警：本函数用于启动恢复 WAL(.mem)，
        // 整目录枚举失败 = 所有 .mem 都被当作不存在 = WAL 数据静默不恢复。
        println("[badger] list .mem files failed in dir ${dir}, WAL recovery entries may be lost: " + e.toString())
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
