# Phase 3: 核心功能设计文档

**项目名称：** badgercj  
**阶段：** Phase 3 - 核心功能  
**日期：** 2026-03-08  
**状态：** 已批准 ✅

---

## 执行摘要

本文档定义 Phase 3 的完整设计，包含 4 个核心模块：MemTable + WAL、LevelHandler、DB API + 简化事务、Compaction。设计目标是实现可用的 LSM Tree KV 数据库，支持 WAL 崩溃恢复，并提供可扩展到完整事务的简化版事务 API。

**核心特性：**
- ✅ MemTable 基于 Skiplist，支持并发读写
- ✅ WAL 支持崩溃恢复
- ✅ LevelHandler 管理多层 LSM Tree
- ✅ DB API 提供原子操作（Get/Set/Delete）
- ✅ 简化事务（Begin/Commit/Rollback），可扩展到完整事务（Phase 4）
- ✅ Compaction 后台压缩任务

---

## 1. 设计目标

### 1.1 功能目标

| 功能模块 | 目标 | 验收标准 |
|---------|------|---------|
| MemTable + WAL | 内存表 + 崩溃恢复 | 写入后 kill 进程，重启能恢复数据 |
| LevelHandler | 多层 LSM Tree 管理 | 能从 SSTable 读取数据 |
| DB API | 基础 KV 操作 | Get/Set/Delete 原子操作通过测试 |
| 简化事务 | Begin/Commit/Rollback | 支持本地写缓冲，Commit 写入 MemTable |
| Compaction | 后台压缩 | L0 -> L1 压缩正常工作 |

### 1.2 非功能目标

- **性能：** 单次 Get/Set 操作 < 1ms（内存场景）
- **可靠性：** WAL 确保数据不丢失
- **可扩展性：** 事务架构支持扩展到完整 ACID（Phase 4）

### 1.3 范围边界

**包含（Phase 3）：**
- ✅ MemTable 并发读写
- ✅ WAL 写入和恢复
- ✅ LevelHandler 查找逻辑
- ✅ DB 原子操作
- ✅ 简化事务（无冲突检测）
- ✅ Compaction 基础逻辑

**不包含（延后到 Phase 4）：**
- ❌ Oracle（全局时间戳管理）
- ❌ 完整事务隔离（SSI）
- ❌ 冲突检测
- ❌ Snapshot（快照读）
- ❌ Iterator（范围扫描）

---

## 2. 架构设计

### 2.1 整体架构

```
┌──────────────────────────────────────────────────┐
│                  Application                      │
└────────────┬─────────────────────────────────────┘
             │
     ┌───────▼────────┐
     │   Transaction  │  (简化版，可扩展)
     │  - begin()     │
     │  - commit()    │
     │  - rollback()  │
     └───────┬────────┘
             │
     ┌───────▼────────────────────────────────────┐
     │              DB (API Layer)                │
     │  - open() / close()                        │
     │  - get() / set() / delete() (原子操作)     │
     │  - newTransaction()                        │
     └───────┬────────────────────────────────────┘
             │
    ┌────────┼─────────┬─────────────┐
    │        │         │             │
┌───▼────┐ ┌─▼────┐ ┌──▼─────┐ ┌────▼────┐
│MemTable│ │Levels│ │VLog    │ │Manifest │
│+ WAL   │ │Ctrl  │ │Manager │ │Manager  │
└───┬────┘ └─┬────┘ └──┬─────┘ └────┬────┘
    │        │         │            │
    │    ┌───▼────┐    │            │
    │    │ Level  │    │            │
    │    │Handler │    │            │
    │    │(L0-L6) │    │            │
    │    └───┬────┘    │            │
    │        │         │            │
    │    ┌───▼────┐    │            │
    │    │ Tables │    │            │
    │    │(.sst)  │    │            │
    │    └───┬────┘    │            │
    │        │         │            │
    └────────┼─────────┼────────────┘
             │         │
        ┌────▼─────────▼────┐
        │   Compaction      │ (后台任务)
        └───────────────────┘
```

### 2.2 数据流

**写入流程：**
```
Application
    ↓
Transaction.set(key, value)
    ↓ (写缓冲区)
Transaction.commit()
    ↓ (提交)
DB.setInternal(key, value)
    ↓
┌─────────────────────┐
│ 1. 检查 MemTable    │
│    - 满则 Flush     │
├─────────────────────┤
│ 2. 写入 MemTable    │
│    a. 写 WAL        │
│    b. 写 Skiplist   │
├─────────────────────┤
│ 3. 大值写 VLog      │
│    - 超阈值         │
│    - 存指针         │
└─────────────────────┘
```

**读取流程：**
```
Application
    ↓
Transaction.get(key)
    ↓
┌─────────────────────┐
│ 1. 查本地 writes    │
│    - 有则返回       │
├─────────────────────┤
│ 2. 查 DB            │
│    a. MemTable      │
│    b. imm MemTables │
│    c. Levels (L0+)  │
│    d. VLog (指针)   │
└─────────────────────┘
```

---

## 3. 模块设计

### 3.1 MemTable + WAL

#### 3.1.1 MemTable

**职责：**
- 基于现有 Skiplist 实现内存表
- 支持 WAL 先写日志
- 追踪大小，支持自动 Flush

**文件：** `src/db/memtable.cj`, `src/db/memtable_test.cj`

**核心接口：**

```cangjie
class MemTable {
    private let sl: Skiplist           // 跳表（已实现）
    private let wal: WAL               // 预写日志
    private let opt: DBOptions
    private var size: AtomicUInt32     // 当前大小
    
    // 初始化（新建或恢复）
    public init(opt: DBOptions, fid: Int, walExists: Bool)
    
    // 写入（先 WAL，后 Skiplist）
    public func put(key: Array<Byte>, value: ValueStruct): Unit
    
    // 读取
    public func get(key: Array<Byte>): Option<ValueStruct>
    
    // 大小检查
    public func sizeInBytes(): UInt64
    
    // 是否需要 Flush
    public func shouldFlush(): Bool
    
    // 迭代器（用于 Flush）
    public func iterator(): SkipIterator
    
    // 增加引用计数（防止 Flush 时被删除）
    public func incrRef(): Unit
    public func decrRef(): Unit
}
```

**关键实现点：**

1. **WAL 先写：**
   ```cangjie
   public func put(key: Array<Byte>, value: ValueStruct): Unit {
       // 1. 先写 WAL（确保持久化）
       wal.write(key, value)
       
       // 2. 再写 Skiplist（内存）
       sl.add(key, value)
       
       // 3. 更新大小
       size.fetchAdd((key.size + value.estimateSize()).toUInt32())
   }
   ```

2. **崩溃恢复：**
   ```cangjie
   public init(opt: DBOptions, fid: Int, walExists: Bool) {
       sl = Skiplist(arenaSize(opt))
       wal = WAL(opt.Dir + "/" + fid.toString() + ".mem")
       
       if (walExists) {
           // 从 WAL 恢复
           wal.replay(this)
       }
   }
   ```

#### 3.1.2 WAL (Write-Ahead Log)

**职责：**
- 记录所有写入操作
- 支持崩溃后重放恢复
- Flush 完成后删除

**文件：** `src/db/wal.cj`, `src/db/wal_test.cj`

**核心接口：**

```cangjie
class WAL {
    private let path: String
    private let fd: File
    private var writeOffset: UInt32
    private let opt: DBOptions
    
    // 打开 WAL（新建或追加）
    public static func open(path: String, opt: DBOptions): WAL
    
    // 写入日志
    public func write(key: Array<Byte>, value: ValueStruct): Unit {
       let entry = LogEntry(key, value)  // 使用现有 LogEntry
       let data = entry.encode()
       
       fd.writeAt(writeOffset, data)
       writeOffset += data.size.toUInt32()
       
       // 确保写入磁盘（fsync）
       fd.sync()
   }
   
   // 读取所有 entries（恢复用）
   public func readAll(): ArrayList<LogEntry> {
       let entries = ArrayList<LogEntry>()
       var offset: UInt32 = 0
       
       while (offset < fd.size()) {
           let entry = LogEntry.decode(fd, offset)
           entries.add(entry)
           offset += entry.size()
       }
       
       return entries
   }
   
   // 重放到 MemTable
   public func replay(mt: MemTable): Unit {
       let entries = readAll()
       for (entry in entries) {
           mt.put(entry.key, entry.value)
       }
   }
   
   // 删除 WAL（Flush 完成）
   public func delete(): Unit {
       fd.close()
       os.remove(path)
   }
}
```

**WAL 文件格式：**
- 与 Value Log 使用相同的 `LogEntry` 格式
- 每条记录包含：CRC32 + header + key + value

#### 3.1.3 测试用例

```cangjie
@Test
func testMemTablePutAndGet() {
    let mt = MemTable(opt)
    mt.put("key1".toArray(), ValueStruct("value1"))
    
    let result = mt.get("key1".toArray())
    Assert.isTrue(result.isSome())
    Assert.equal("value1", result.orElse("").toString())
}

@Test
func testMemTableWALRecovery() {
    // 1. 写入数据
    let mt1 = MemTable(opt, fid: 1, walExists: false)
    mt1.put("key1".toArray(), ValueStruct("value1"))
    mt1.put("key2".toArray(), ValueStruct("value2"))
    
    // 2. 模拟崩溃（不关闭）
    
    // 3. 重新打开（恢复）
    let mt2 = MemTable(opt, fid: 1, walExists: true)
    
    // 4. 验证数据
    Assert.equal("value1", mt2.get("key1".toArray()).orElse([]).toString())
    Assert.equal("value2", mt2.get("key2".toArray()).orElse([]).toString())
}

@Test
func testMemTableShouldFlush() {
    let opt = DBOptions(MemTableSize: 1024)
    let mt = MemTable(opt)
    
    // 写入超过阈值
    for (i in 0..100) {
        mt.put("key${i}".toArray(), ValueStruct("value${i}"))
    }
    
    Assert.isTrue(mt.shouldFlush())
}
```

---

### 3.2 LevelHandler

#### 3.2.1 LevelsController

**职责：**
- 管理所有层级的 LevelHandler
- 协调多层查找
- 管理文件 ID 分配

**文件：** `src/db/levels.cj`, `src/db/levels_test.cj`

**核心接口：**

```cangjie
class LevelsController {
    private let levels: Array<LevelHandler>
    private let db: DB
    private let nextFileID: AtomicUInt64
    
    // 初始化（从 Manifest 恢复）
    public init(db: DB, manifest: Manifest) {
       levels = Array<LevelHandler>(opt.MaxLevels, {i => 
           LevelHandler(db, level: i)
       })
       nextFileID = AtomicUInt64(manifest.nextFileID())
       
       // 从 Manifest 恢复 tables
       for ((fileID, tableManifest) in manifest.tables) {
           let table = openTable(fileID, tableManifest)
           levels[tableManifest.level].addTable(table)
       }
   }
   
   // 查找 key
   public func get(key: Array<Byte>, readTs: UInt64): Option<ValueStruct> {
       // 从 L0 到 Ln 逐层查找
       for (level in levels) {
           let result = level.get(key, readTs)
           if (result.isSome()) {
               return result
           }
       }
       return None
   }
   
   // 添加新 Table（Flush 后）
   public func addTable(level: Int, table: Table): Unit {
       levels[level].addTable(table)
   }
   
   // 获取下一文件 ID
   public func nextFileID(): UInt64 {
       return nextFileID.fetchAdd(1)
   }
   
   // 检查是否需要 Compaction
   public func shouldCompact(): Bool {
       // L0 tables 过多
       if (levels[0].numTables() > opt.NumLevelZeroTables) {
           return true
       }
       
       // 某层大小超过限制
       for (i in 1..<opt.MaxLevels) {
           if (levels[i].totalSize() > opt.levelMaxSize(i)) {
               return true
           }
       }
       
       return false
   }
}
```

#### 3.2.2 LevelHandler

**职责：**
- 管理单层的 SSTable 文件
- 提供查找接口
- 追踪层大小

**核心接口：**

```cangjie
class LevelHandler {
    private let level: Int
    private let db: DB
    private var tables: ArrayList<Table>
    private var totalSize: Int64
    
    // 查找
    public func get(key: Array<Byte>, readTs: UInt64): Option<ValueStruct> {
       if (level == 0) {
           // L0: 检查所有 table（可能有重叠）
           for (table in tables) {
               let result = table.get(key, readTs)
               if (result.isSome()) {
                   return result
               }
           }
           return None
       }
       
       // L1+: 二分查找（无重叠）
       let idx = binarySearchTable(key)
       if (idx >= 0) {
           return tables[idx].get(key, readTs)
       }
       return None
   }
   
   // 添加 Table
   public func addTable(table: Table): Unit {
       tables.add(table)
       totalSize += table.size()
       
       // 非 L0 需要保持有序
       if (level > 0) {
           tables.sort((a, b) => a.compare(b))
       }
   }
   
   // 获取重叠的 tables（Compaction 用）
   public func getOverlappingTables(kr: KeyRange): Array<Table> {
       if (level == 0) {
           // L0: 检查所有
           return tables.filter({t => t.overlaps(kr)})
       }
       
       // L1+: 二分查找范围
       let left = findFirstLargerOrEqual(kr.left)
       let right = findLastSmallerOrEqual(kr.right)
       return tables[left..right]
   }
   
   // 删除 Table（Compaction 后）
   public func deleteTables(tableIDs: Array<UInt64>): Unit {
       tables = tables.filter({t => !tableIDs.contains(t.id)})
   }
   
   private func binarySearchTable(key: Array<Byte>): Int {
       // 二分查找
   }
}
```

#### 3.2.3 测试用例

```cangjie
@Test
func testLevelHandlerGet() {
    let handler = LevelHandler(db, level: 1)
    
    // 添加测试 table
    let table = createTestTable([
        ("key1", "value1"),
        ("key2", "value2")
    ])
    handler.addTable(table)
    
    // 查找
    let result = handler.get("key1".toArray(), maxTs)
    Assert.isTrue(result.isSome())
}

@Test
func testLevelsControllerMultiLevel() {
    let lc = LevelsController(db, manifest)
    
    // L0 有 key1
    lc.levels[0].addTable(createTestTable([("key1", "v1")]))
    
    // L1 有 key2
    lc.levels[1].addTable(createTestTable([("key2", "v2")]))
    
    // 查找
    Assert.equal("v1", lc.get("key1".toArray(), maxTs).toString())
    Assert.equal("v2", lc.get("key2".toArray(), maxTs).toString())
}
```

---

### 3.3 DB API + 简化事务

#### 3.3.1 DB 主类

**职责：**
- 提供主要 API 入口
- 协调 MemTable、LevelHandler、VLog
- 处理 Flush 逻辑

**文件：** `src/db/db.cj`, `src/db/db_test.cj`

**核心接口：**

```cangjie
public class DB {
    private let opt: DBOptions
    private let mt: MemTable              // 当前 MemTable
    private let imm: ArrayList<MemTable>  // 不可变 MemTable
    private let lc: LevelsController      // Level Controller
    private let vlog: ValueLog            // Value Log
    private let manifest: Manifest        // Manifest
    private let lock: Mutex
    
    // 打开数据库
    public static func open(opt: DBOptions): DB {
       // 1. 创建/检查目录
       os.mkdir(opt.Dir, recursive: true)
       
       // 2. 打开 Manifest
       let manifest = Manifest.open(opt)
       
       // 3. 打开 Level Controller
       let lc = LevelsController(db, manifest)
       
       // 4. 打开 Value Log
       let vlog = ValueLog.open(opt)
       
       // 5. 恢复 MemTable（从 WAL）
       let mt = recoverMemTable(opt)
       
       // 6. 启动后台任务
       db.startCompaction()
       
       return DB(opt, mt, lc, vlog, manifest)
   }
   
   // 关闭数据库
   public func close(): Unit {
       compaction.stop()
       mt.wal.close()
       vlog.close()
       manifest.close()
   }
   
   // 原子操作：Get
   public func get(key: Array<Byte>): Option<Array<Byte>> {
       synchronized (lock) {
           return getInternal(key, maxVersion)
       }
   }
   
   // 原子操作：Set
   public func set(key: Array<Byte>, value: Array<Byte>): Unit {
       synchronized (lock) {
           setInternal(key, value, MetaValue)
       }
   }
   
   // 原子操作：Delete
   public func delete(key: Array<Byte>): Unit {
       synchronized (lock) {
           setInternal(key, [], MetaDelete)
       }
   }
   
   // 创建事务
   public func newTransaction(): Transaction {
       return Transaction(this)
   }
   
   // 内部：读取逻辑
   private func getInternal(key: Array<Byte>, readTs: UInt64): Option<Array<Byte>> {
       // 1. 查当前 MemTable
       let result = mt.get(key)
       if (result.isSome()) {
           return getValue(result)
       }
       
       // 2. 查 imm MemTables（从新到旧）
       for (i in imm.size-1..0) {
           let result = imm[i].get(key)
           if (result.isSome()) {
               return getValue(result)
           }
       }
       
       // 3. 查 Levels
       let result = lc.get(key, readTs)
       if (result.isSome()) {
           return getValue(result)
       }
       
       return None
   }
   
   // 内部：写入逻辑
   private func setInternal(key: Array<Byte>, value: Array<Byte>, meta: Byte): Unit {
       // 1. 检查 MemTable 是否需要 Flush
       if (mt.shouldFlush()) {
           flushMemTable()
       }
       
       // 2. 构造 ValueStruct
       var vs = ValueStruct(value, meta)
       
       // 3. 如果 value 大，写入 Value Log
       if (value.size > opt.ValueThreshold) {
           let vp = vlog.write(key, vs)
           vs.value = vp.encode()
           vs.meta = MetaValuePointer
       }
       
       // 4. 写入 MemTable
       mt.put(key, vs)
   }
   
   // Flush MemTable
   private func flushMemTable(): Unit {
       // 1. 将 mt 移到 imm
       imm.add(mt)
       
       // 2. 创建新 MemTable
       mt = newMemTable()
       
       // 3. 后台 Flush（异步）
       spawn {
           flushToDisk(imm.last())
       }
   }
   
   // Flush 到 SSTable
   private func flushToDisk(mt: MemTable): Unit {
       // 1. 构建 SSTable
       let builder = TableBuilder()
       let iter = mt.iterator()
       
       while (iter.hasNext()) {
           let entry = iter.next()
           builder.add(entry.key, entry.value)
       }
       
       // 2. 生成文件
       let fileID = lc.nextFileID()
       let table = builder.build(fileID)
       
       // 3. 更新 Manifest
       manifest.addChange(ManifestChange(
           id: fileID,
           op: CREATE,
           level: 0
       ))
       
       // 4. 添加到 Level 0
       lc.addTable(0, table)
       
       // 5. 删除 WAL
       mt.wal.delete()
       mt.decrRef()
   }
   
   // 解析 Value（处理 ValuePointer）
   private func getValue(vs: ValueStruct): Option<Array<Byte>> {
       if (vs.isValuePointer()) {
           let vp = ValuePointer.decode(vs.value)
           return vlog.read(vp)
       }
       return Some(vs.value)
   }
}
```

#### 3.3.2 Transaction（简化版）

**职责：**
- 提供事务 API
- 本地写缓冲区
- 可扩展到完整事务（Phase 4）

**文件：** `src/db/transaction.cj`, `src/db/transaction_test.cj`

**核心接口：**

```cangjie
public class Transaction {
    private let db: DB
    private let readTs: UInt64              // 读时间戳
    private let writes: HashMap<Array<Byte>, Entry>  // 写缓冲区
    private var committed: Bool = false
    
    // 初始化
    public init(db: DB) {
       this.db = db
       this.readTs = db.maxVersion()  // 简化：当前版本
       this.writes = HashMap<Array<Byte>, Entry>()
   }
   
   // Get
   public func get(key: Array<Byte>): Option<Array<Byte>> {
       // 1. 查本地 writes
       if (writes.contains(key)) {
           let entry = writes[key]
           if (entry.isDelete()) {
               return None
           }
           return Some(entry.value)
       }
       
       // 2. 查 DB
       return db.get(key)
   }
   
   // Set
   public func set(key: Array<Byte>, value: Array<Byte>): Unit {
       writes[key] = Entry(
           key: key,
           value: value,
           version: readTs,
           meta: MetaValue
       )
   }
   
   // Delete
   public func delete(key: Array<Byte>): Unit {
       writes[key] = Entry(
           key: key,
           value: [],
           version: readTs,
           meta: MetaDelete
       )
   }
   
   // Commit
   public func commit(): Unit {
       if (committed) {
           throw IllegalStateException("Transaction already committed")
       }
       
       // 简化版：直接写入（无冲突检测）
       synchronized (db.lock) {
           for ((key, entry) in writes) {
               db.setInternal(key, entry.value, entry.meta)
           }
       }
       
       committed = true
   }
   
   // Rollback
   public func rollback(): Unit {
       writes.clear()
       committed = true
   }
   
   // 析构函数（检查未提交）
   protected func finalize() {
       if (!committed) {
           // 警告：未提交的事务
           db.opt.Logger.warn("Transaction not committed, rolling back")
           rollback()
       }
   }
}
```

**Phase 4 扩展点：**

```cangjie
// Phase 4: 完整事务扩展
public class CompleteTransaction extends Transaction {
    private let oracle: Oracle
    private let readSet: HashSet<Array<Byte>>  // 跟踪读 key
    
    public func get(key: Array<Byte>): Option<Array<Byte>> {
        readSet.add(key)  // 记录读
        return super.get(key)
    }
    
    public func commit(): Unit {
        let commitTs = oracle.readCommitTs()
        
        // 冲突检测
        if (oracle.hasConflict(readSet, readTs, commitTs)) {
            throw ConflictException("Transaction conflict detected")
        }
        
        // 写入
        super.commit()
        
        oracle.doneCommit(commitTs)
    }
}
```

#### 3.3.3 测试用例

```cangjie
@Test
func testDBOpenAndClose() {
    let db = DB.open(DBOptions(Dir: "/tmp/testdb"))
    
    db.set("key1".toArray(), "value1".toArray())
    let result = db.get("key1".toArray())
    
    Assert.equal("value1", result.orElse([]).toString())
    
    db.close()
}

@Test
func testDBCrashRecovery() {
    let path = "/tmp/testdb"
    
    // 1. 写入数据
    let db1 = DB.open(DBOptions(Dir: path))
    db1.set("key1".toArray(), "value1".toArray())
    db1.set("key2".toArray(), "value2".toArray())
    // 不 close，模拟崩溃
    
    // 2. 重新打开
    let db2 = DB.open(DBOptions(Dir: path))
    
    // 3. 验证数据
    Assert.equal("value1", db2.get("key1".toArray()).toString())
    Assert.equal("value2", db2.get("key2".toArray()).toString())
    
    db2.close()
}

@Test
func testTransactionBasic() {
    let db = DB.open(DBOptions(Dir: "/tmp/testdb"))
    
    let txn = db.newTransaction()
    txn.set("key1".toArray(), "value1".toArray())
    txn.set("key2".toArray(), "value2".toArray())
    txn.commit()
    
    Assert.equal("value1", db.get("key1".toArray()).toString())
    Assert.equal("value2", db.get("key2".toArray()).toString())
    
    db.close()
}

@Test
func testTransactionRollback() {
    let db = DB.open(DBOptions(Dir: "/tmp/testdb"))
    
    db.set("key1".toArray(), "value1".toArray())
    
    let txn = db.newTransaction()
    txn.set("key1".toArray(), "modified".toArray())
    txn.rollback()
    
    // 应该还是原值
    Assert.equal("value1", db.get("key1".toArray()).toString())
    
    db.close()
}

@Test
func testDBLargeValue() {
    let opt = DBOptions(
        Dir: "/tmp/testdb",
        ValueThreshold: 64
    )
    let db = DB.open(opt)
    
    // 写入大值（超过阈值）
    let largeValue = Array<Byte>(1000, {i => i.toByte()})
    db.set("key1".toArray(), largeValue)
    
    // 读取
    let result = db.get("key1".toArray())
    Assert.equal(largeValue, result.orElse([]))
    
    db.close()
}
```

---

### 3.4 Compaction

#### 3.4.1 Compaction 类

**职责：**
- 后台压缩任务
- 合并多层 SSTable
- 清理无效数据

**文件：** `src/db/compaction.cj`, `src/db/compaction_test.cj`

**核心接口：**

```cangjie
class Compaction {
    private let db: DB
    private let running: AtomicBool
    
    // 启动
    public func start(): Unit {
       running.store(true)
       
       spawn {
           while (running.load()) {
               runCompaction()
               sleep(opt.CompactionInterval)  // 默认 100ms
           }
       }
   }
   
   // 停止
   public func stop(): Unit {
       running.store(false)
   }
   
   // 执行压缩
   private func runCompaction(): Unit {
       // 1. 检查是否需要
       if (!db.lc.shouldCompact()) {
           return
       }
       
       // 2. 选择压缩任务
       let cdef = pickCompaction()
       if (cdef == None) {
           return
       }
       
       // 3. 执行
       doCompact(cdef)
   }
   
   // 选择压缩任务
   private func pickCompaction(): Option<CompactionDef> {
       // L0 -> L1
       if (db.lc.levels[0].numTables() > opt.NumLevelZeroTables) {
           let tables = db.lc.levels[0].tables
           return Some(CompactionDef(
               level: 0,
               tables: tables[0..opt.L0CompactionConcurrency]
           ))
       }
       
       // Ln -> Ln+1
       for (i in 1..<opt.MaxLevels-1) {
           if (db.lc.levels[i].totalSize() > opt.levelMaxSize(i)) {
               let tables = pickTablesForCompaction(i)
               return Some(CompactionDef(
                   level: i,
                   tables: tables
               ))
           }
       }
       
       return None
   }
   
   // 执行压缩
   private func doCompact(cdef: CompactionDef): Unit {
       // 1. 获取重叠 tables
       let thisLevel = cdef.level
       let nextLevel = cdef.level + 1
       
       let thisTables = cdef.tables
       let nextTables = db.lc.levels[nextLevel].getOverlappingTables(
           getKeyRange(thisTables)
       )
       
       // 2. 合并迭代器
       let iter = mergeIterator(thisTables + nextTables)
       
       // 3. 构建新 tables
       let builder = TableBuilder()
       var currentSize: Int64 = 0
       let newTables = ArrayList<Table>()
       
       while (iter.hasNext()) {
           let entry = iter.next()
           
           // 跳过删除标记（如果最旧版本）
           if (entry.isDelete() && !hasOlderVersion(entry.key)) {
               continue
           }
           
           builder.add(entry.key, entry.value)
           currentSize += entry.size()
           
           // 达到目标大小，生成新 table
           if (currentSize >= opt.TableSize) {
               let table = builder.build(db.lc.nextFileID())
               newTables.add(table)
               builder = TableBuilder()
               currentSize = 0
           }
       }
       
       // 最后一个 table
       if (currentSize > 0) {
           let table = builder.build(db.lc.nextFileID())
           newTables.add(table)
       }
       
       // 4. 更新 Manifest（原子操作）
       synchronized (db.manifest.lock) {
           // 添加新 tables
           for (table in newTables) {
               db.manifest.addChange(ManifestChange(
                   id: table.id,
                   op: CREATE,
                   level: nextLevel
               ))
           }
           
           // 删除旧 tables
           for (table in thisTables + nextTables) {
               db.manifest.addChange(ManifestChange(
                   id: table.id,
                   op: DELETE,
                   level: thisLevel  // 或 nextLevel
               ))
           }
       }
       
       // 5. 应用到内存
       db.lc.levels[nextLevel].addTables(newTables)
       db.lc.levels[thisLevel].deleteTables(thisTables.map({t => t.id}))
       db.lc.levels[nextLevel].deleteTables(nextTables.map({t => t.id}))
       
       // 6. 删除文件
       for (table in thisTables + nextTables) {
           os.remove(table.path)
       }
   }
   
   // 合并迭代器
   private func mergeIterator(tables: Array<Table>): MergeIterator {
       return MergeIterator(tables.map({t => t.iterator()}))
   }
}

// 压缩定义
struct CompactionDef {
    let level: Int
    let tables: Array<Table>
}
```

#### 3.4.2 测试用例

```cangjie
@Test
func testCompactionL0ToL1() {
    let opt = DBOptions(
        Dir: "/tmp/testdb",
        NumLevelZeroTables: 2,
        MemTableSize: 1024
    )
    let db = DB.open(opt)
    
    // 写入触发 Flush
    for (i in 0..100) {
        db.set("key${i}".toArray(), "value${i}".toArray())
    }
    
    // 等待 Compaction
    sleep(1000)
    
    // 验证 L0 减少或清空
    Assert.isTrue(db.lc.levels[0].numTables() < 3)
    
    db.close()
}

@Test
func testCompactionMergeDelete() {
    let db = DB.open(DBOptions(Dir: "/tmp/testdb"))
    
    // 写入 + 删除
    db.set("key1".toArray(), "value1".toArray())
    db.delete("key1".toArray())
    
    // 手动触发 Compaction
    db.compaction.runCompaction()
    
    // 验证 key1 完全消失（删除标记被清理）
    Assert.isFalse(db.get("key1".toArray()).isSome())
    
    db.close()
}
```

---

## 4. 实施计划

### 4.1 Week 1: MemTable + WAL

**时间：** Day 1-7

**任务清单：**

| 任务 | 预计时间 | 文件 | 状态 |
|------|---------|------|------|
| MemTable 基础实现 | 3h | `src/db/memtable.cj` | ⏸️ 待开始 |
| WAL 写入逻辑 | 2h | `src/db/wal.cj` | ⏸️ 待开始 |
| WAL 恢复逻辑 | 2h | `src/db/wal.cj` | ⏸️ 待开始 |
| MemTable 单元测试 | 3h | `src/db/memtable_test.cj` | ⏸️ 待开始 |
| WAL 单元测试 | 2h | `src/db/wal_test.cj` | ⏸️ 待开始 |
| 集成测试 | 2h | - | ⏸️ 待开始 |

**验收标准：**
- ✅ MemTable 读写正常
- ✅ WAL 写入和恢复正常
- ✅ 模拟崩溃能恢复数据
- ✅ 单元测试 ≥ 10 个，全部通过

---

### 4.2 Week 2: LevelHandler

**时间：** Day 8-14

**任务清单：**

| 任务 | 预计时间 | 文件 | 状态 |
|------|---------|------|------|
| LevelsController 基础 | 3h | `src/db/levels.cj` | ⏸️ 待开始 |
| LevelHandler 实现 | 3h | `src/db/level_handler.cj` | ⏸️ 待开始 |
| 集成 SSTable Reader | 2h | - | ⏸️ 待开始 |
| 单元测试 | 3h | `src/db/levels_test.cj` | ⏸️ 待开始 |
| 性能测试 | 2h | - | ⏸️ 待开始 |

**验收标准：**
- ✅ 多层查找正常
- ✅ L0 和 L1+ 查找逻辑不同
- ✅ 单元测试 ≥ 8 个，全部通过

---

### 4.3 Week 3: DB API + Transaction

**时间：** Day 15-21

**任务清单：**

| 任务 | 预计时间 | 文件 | 状态 |
|------|---------|------|------|
| DB 主类实现 | 4h | `src/db/db.cj` | ⏸️ 待开始 |
| Transaction 实现 | 3h | `src/db/transaction.cj` | ⏸️ 待开始 |
| Flush 逻辑 | 3h | `src/db/db.cj` | ⏸️ 待开始 |
| 集成测试 | 4h | `src/db/db_test.cj` | ⏸️ 待开始 |
| 事务测试 | 3h | `src/db/transaction_test.cj` | ⏸️ 待开始 |

**验收标准：**
- ✅ DB open/close/get/set/delete 正常
- ✅ Transaction begin/commit/rollback 正常
- ✅ Flush 后能从 SSTable 读取
- ✅ 集成测试 ≥ 12 个，全部通过

---

### 4.4 Week 4: Compaction

**时间：** Day 22-28

**任务清单：**

| 任务 | 预计时间 | 文件 | 状态 |
|------|---------|------|------|
| Compaction 基础逻辑 | 4h | `src/db/compaction.cj` | ⏸️ 待开始 |
| 后台任务管理 | 2h | `src/db/compaction.cj` | ⏸️ 待开始 |
| Manifest 更新 | 2h | - | ⏸️ 待开始 |
| 单元测试 | 3h | `src/db/compaction_test.cj` | ⏸️ 待开始 |
| 性能测试 | 2h | - | ⏸️ 待开始 |

**验收标准：**
- ✅ Compaction 后台运行正常
- ✅ L0 -> L1 压缩正常
- ✅ Manifest 更新正确
- ✅ 单元测试 ≥ 6 个，全部通过

---

## 5. 测试策略

### 5.1 单元测试

**目标覆盖率：** ≥ 70%

**测试分布：**
- MemTable: 10 个测试
- WAL: 8 个测试
- LevelHandler: 8 个测试
- DB: 12 个测试
- Transaction: 10 个测试
- Compaction: 6 个测试

**总计：** 54 个单元测试

### 5.2 集成测试

**关键场景：**
1. 写入 -> Flush -> 读取
2. 写入 -> 崩溃 -> 恢复
3. 多次写入 -> Compaction -> 验证
4. 大值写入（超过阈值）

### 5.3 性能测试

**基准场景：**
- 1000 次顺序写入
- 1000 次随机读取
- 1000 次事务写入

---

## 6. 风险管理

### 6.1 技术风险

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|----------|
| WAL 恢复 bug | 中 | 高 | 大量崩溃恢复测试 |
| Compaction 并发 bug | 高 | 高 | 简化版本先单线程 |
| Flush 丢失数据 | 中 | 高 | WAL 确保原子性 |
| 性能不达标 | 中 | 中 | 先保证正确性 |

### 6.2 缓解策略

1. **单元测试优先** - 每个模块完成立即测试
2. **增量集成** - 每周集成一次，早发现问题
3. **崩溃测试** - 专门的崩溃恢复测试套件
4. **性能监控** - 持续监控关键指标

---

## 7. 后续扩展

### 7.1 Phase 4 扩展点

**事务扩展：**
- 添加 Oracle（全局时间戳）
- 添加冲突检测
- 实现 SSI 隔离

**其他功能：**
- Snapshot（快照读）
- Iterator（范围扫描）

### 7.2 接口预留

所有 Phase 4 需要的接口已在 Phase 3 预留：
- Transaction 支持继承扩展
- DB 支持 readTs 参数
- Manifest 支持版本管理

---

## 8. 成功标准

### 8.1 功能验收

- [ ] 所有单元测试通过（≥ 54 个）
- [ ] 所有集成测试通过
- [ ] 崩溃恢复测试通过
- [ ] Compaction 功能正常

### 8.2 质量验收

- [ ] 代码覆盖率 ≥ 70%
- [ ] 无已知严重 bug
- [ ] 性能符合预期

### 8.3 文档验收

- [ ] API 文档完整
- [ ] 架构文档更新
- [ ] 测试报告完整

---

**文档版本：** v1.0  
**创建时间：** 2026-03-08  
**批准时间：** 2026-03-08  
**作者：** AI Code Agent  
**审阅：** User ✅
