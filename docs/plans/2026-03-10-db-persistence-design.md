# DB 持久化功能设计

**创建日期：** 2026-03-10
**作者：** AI Code Agent
**状态:** ✅ 已完成
**完成日期:** 2026-03-10

---

## 目标

实现 **badger-cj** 的 **完整持久化功能**（DB Persistence），支持：
1. **正常关闭恢复** - `db.close()` 后重新 `db.open()` 能读取之前写入的数据
2. **崩溃恢复** - 进程被 kill 后重启，能恢复已提交的数据
3. **严格持久化** - `db.close()` 时 flush MemTable 数据到 SSTable

---

## 设计决策

### 1. 持久化级别
- ✅ **完整持久化** - WAL + MANIFEST + SSTable 全部持久化
- ✅ 支持正常关闭和崩溃恢复

### 2. 恢复行为
- ✅ **严格持久化** - `db.close()` 时必须 flush MemTable 到 SSTable
- ✅ 确保所有写入都持久化到磁盘

### 3. MANIFEST 格式
- ✅ **追加式（Append-Only）** - 兼容 Go BadgerDB
- ✅ 使用现有的 `ManifestChangeSet.encode()` Protobuf 编码
- ✅ 每次变更追加到文件末尾

---

## 架构设计

### 整体流程

```
┌─────────────────────────────────────────────────────────────┐
│                        DB.open()                             │
├─────────────────────────────────────────────────────────────┤
│  1. 加载 MANIFEST 文件 → 重建 LevelsController              │
│  2. 从磁盘加载 SSTable 文件到 LevelHandler                   │
│  3. 重放 WAL → 恢复 MemTable                                 │
│  4. 恢复 nextFileID、version 等状态                          │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                        DB.close()                            │
├─────────────────────────────────────────────────────────────┤
│  1. Flush 当前 MemTable → SSTable 文件                      │
│  2. 记录 ManifestChange (Create Table)                       │
│  3. 保存 MANIFEST 变更到磁盘                                 │
│  4. 删除已 flush 的 WAL 文件                                 │
│  5. 关闭所有文件句柄                                         │
└─────────────────────────────────────────────────────────────┘
```

---

## 模块设计

### 模块 1: ManifestFile（新增）

**文件：** `src/manifest/manifest_file.cj`

**职责：**
- 管理 MANIFEST 文件的读写
- 追加 ManifestChangeSet 到文件
- 从文件加载并重放变更

**关键接口：**
```cangjie
public class ManifestFile {
    private let path: String
    private let file: File
    private var manifest: Manifest
    
    // 打开或创建 MANIFEST 文件
    public static func open(path: String): ManifestFile
    
    // 追加变更到文件
    public func saveChanges(changes: ManifestChangeSet): Unit
    
    // 获取当前 Manifest
    public func getManifest(): Manifest
    
    // 关闭文件
    public func close(): Unit
}
```

**文件格式（追加式）：**
```
┌────────────────┬────────────────┬────────────────┐
│ ChangeSet Len  │ ChangeSet Data │ ChangeSet Len  │ ...
│ (4 bytes LE)   │ (varint + pb)  │ (4 bytes LE)   │
└────────────────┴────────────────┴────────────────┘
```

**实现细节：**
1. `open()` - 打开文件，读取所有 ChangeSet，重放重建 Manifest
2. `saveChanges()` - 序列化 ChangeSet，写入文件（长度 + 数据）
3. 使用 BufferedOutputStream 提升写入性能

---

### 模块 2: DB.open() 恢复逻辑（修改）

**文件：** `src/db/db.cj`

**修改点：**

```cangjie
public static func open(opt: DBOptions): DB {
    // 1. 打开或创建目录
    if (!exists(Path(opt.Dir))) {
        Directory.create(Path(opt.Dir), recursive: true)
    }
    
    // 2. 加载 MANIFEST
    let manifestPath = helpers.manifestPath(opt.Dir)
    let manifestFile = ManifestFile.open(manifestPath)
    let manifest = manifestFile.getManifest()
    
    // 3. 从 MANIFEST 恢复 LevelsController
    let lc = LevelsController(manifest: manifest, dir: opt.Dir)
    lc.loadTables() // 从磁盘加载 SSTable
    
    // 4. 恢复 MemTable (重放 WAL)
    let fid = Int64(manifest.nextFileID)
    let mt = MemTable(opt, fid, false)
    let walPath = helpers.walPath(opt.Dir, fid)
    if (exists(Path(walPath))) {
        let wal = WAL.open(walPath)
        wal.replay(mt)
        wal.close()
    }
    
    // 5. 创建 DB 实例
    let vlog = VLogManager(Path(opt.Dir))
    let db = DB(opt, mt, manifest, manifestFile, lc, vlog)
    db.running = AtomicBool(true)
    let fut = spawn { db.flushLoop() }
    db.flushFut = Some(fut)
    return db
}
```

**恢复顺序：**
1. MANIFEST → 重建 LSM 树结构
2. SSTable → 加载到 LevelHandler
3. WAL → 重放到 MemTable

---

### 模块 3: DB.close() 持久化逻辑（修改）

**文件：** `src/db/db.cj`

**修改点：**

```cangjie
public func close(): Unit {
    running.store(false)
    if (let Some(fut) <- flushFut) {
        fut.get()
    }
    
    lock.writeLock.lock()
    try {
        // 1. Flush 当前 MemTable
        if (!mt.isEmpty()) {
            let changes = flushMemTableToDisk()
            manifestFile.saveChanges(changes)
        }
        
        // 2. Flush immutable memtables
        for (immMt in imm) {
            let changes = flushMemTableToDisk(immMt)
            manifestFile.saveChanges(changes)
        }
        imm.clear()
        
        // 3. 删除已 flush 的 WAL 文件
        mt.deleteWAL()
        
        // 4. 关闭其他资源
        vlog.close()
        oracle.stop()
        manifestFile.close()
    } finally {
        lock.writeLock.unlock()
    }
}

private func flushMemTableToDisk(mt: MemTable): ManifestChangeSet {
    // 1. 构建 SSTable
    let builder = TableBuilder()
    let iter = mt.iterator()
    while (iter.hasNext()) {
        if (let Some((key, vs)) <- iter.next()) {
            builder.add(key, vs)
        }
    }
    let data = builder.finish()
    
    // 2. 写入文件
    let tableID = nextFileID.fetchAdd(1)
    let path = helpers.sstablePath(opt.Dir, tableID)
    writeFileSync(path, data)
    
    // 3. 添加到 LevelsController
    let table = Table(tableID, data)
    lc.addTable(0, table)
    
    // 4. 返回 ManifestChange
    let changes = ManifestChangeSet()
    changes.add(ManifestChange(tableID, ManifestChangeOp.Create, level: 0))
    return changes
}
```

---

### 模块 4: LevelsController SSTable 加载（修改）

**文件：** `src/db/levels.cj`

**新增属性：**
```cangjie
public class LevelsController {
    private let levels: ArrayList<LevelHandler>
    private let manifest: Manifest
    private let dir: String  // 新增：数据目录
    private let nextFileID: UInt64
    
    public init(manifest: Manifest, dir!: String = "") {
        this.manifest = manifest
        this.dir = dir
        this.nextFileID = manifest.nextFileID
        this.levels = ArrayList<LevelHandler>()
        
        for (i in 0..7) {
            levels.add(LevelHandler(i))
        }
    }
}
```

**新增方法：**
```cangjie
public func loadTables(): Unit {
    for (level in 0..7) {
        let tables = manifest.levels[level]
        for (tableInfo in tables) {
            let path = helpers.sstablePath(dir, tableInfo.id)
            if (exists(Path(path))) {
                let data = readFileSync(path)
                let table = Table(tableInfo.id, data)
                levels[level].addTable(table)
            }
        }
    }
}
```

---

### 模块 5: 文件路径辅助函数（新增）

**文件：** `src/db/helpers.cj`

**新增函数：**
```cangjie
public func manifestPath(dir: String): String {
    "${dir}/MANIFEST"
}

public func walPath(dir: String, fid: Int64): String {
    let fidStr = fid.toString()
    let padded = "0".repeat(6 - fidStr.size) + fidStr
    "${dir}/${padded}.wal"
}

public func sstablePath(dir: String, fid: UInt64): String {
    let fidStr = fid.toString()
    let padded = "0".repeat(6 - fidStr.size) + fidStr
    "${dir}/${padded}.sst"
}
```

**目录结构：**
```
/opt.Dir/
├── MANIFEST          # 元数据文件
├── 000001.wal        # WAL 文件
├── 000002.sst        # SSTable 文件
├── 000003.sst        # SSTable 文件
└── 000001.vlog       # ValueLog 文件
```

---

### 模块 6: MemTable WAL 管理（修改）

**文件：** `src/db/memtable.cj`

**新增方法：**
```cangjie
public func deleteWAL(): Unit {
    if (let Some(w) <- wal) {
        w.delete()
        wal = None
    }
}

public func isEmpty(): Bool {
    return sl.size() == 0
}
```

---

### 模块 7: 集成测试（新增）

**文件：** `src/db/persistence_test.cj`

**测试用例：**
```cangjie
@Test
public func testBasicPersistence(): Unit {
    // 1. 创建 DB 并写入数据
    let dir = createTempDir()
    let db = DB.open(DBOptions(Dir: dir))
    db.set("key1", "value1")
    db.set("key2", "value2")
    
    // 2. 关闭 DB
    db.close()
    
    // 3. 重新打开 DB
    let db2 = DB.open(DBOptions(Dir: dir))
    
    // 4. 验证数据
    assert(db2.get("key1") == Some("value1"))
    assert(db2.get("key2") == Some("value2"))
    
    db2.close()
    cleanupTempDir(dir)
}

@Test
public func testCrashRecovery(): Unit {
    // 1. 创建 DB 并写入数据
    let dir = createTempDir()
    let db = DB.open(DBOptions(Dir: dir))
    db.set("key1", "value1")
    db.flushWAL() // 只 flush WAL，不 flush SSTable
    
    // 2. 模拟崩溃（不调用 close）
    // db.close() // 故意不调用
    
    // 3. 重新打开 DB
    let db2 = DB.open(DBOptions(Dir: dir))
    
    // 4. 验证 WAL 恢复
    assert(db2.get("key1") == Some("value1"))
    
    db2.close()
    cleanupTempDir(dir)
}

@Test
public func testMultipleRestarts(): Unit {
    // 测试多次重启
    let dir = createTempDir()
    
    // 第一次写入
    let db1 = DB.open(DBOptions(Dir: dir))
    db1.set("key1", "value1")
    db1.close()
    
    // 第二次写入
    let db2 = DB.open(DBOptions(Dir: dir))
    db2.set("key2", "value2")
    db2.close()
    
    // 第三次读取
    let db3 = DB.open(DBOptions(Dir: dir))
    assert(db3.get("key1") == Some("value1"))
    assert(db3.get("key2") == Some("value2"))
    db3.close()
    
    cleanupTempDir(dir)
}
```

---

## 实现计划

### 阶段 1: ManifestFile（~4h）
- 实现 ManifestFile 类
- 实现 append 和 load 逻辑
- 编写单元测试

### 阶段 2: 文件路径辅助函数（~1h）
- 实现 helpers 函数
- 添加路径生成测试

### 阶段 3: LevelsController 加载（~2h）
- 修改 LevelsController 构造函数
- 实现 loadTables() 方法
- 编写单元测试

### 阶段 4: DB.open() 恢复（~3h）
- 修改 DB.open() 方法
- 集成 ManifestFile、LevelsController、WAL 恢复
- 编写单元测试

### 阶段 5: DB.close() 持久化（~3h）
- 修改 DB.close() 方法
- 实现 flushMemTableToDisk()
- 编写单元测试

### 阶段 6: 集成测试（~2h）
- 编写生命周期测试
- 编写崩溃恢复测试
- 编写多次重启测试

**总预估时间：** ~15h

---

## 风险与缓解

### 风险 1: MANIFEST 文件损坏
- **影响：** 无法恢复 LSM 树结构
- **缓解：** 
  - 定期做 MANIFEST compact（创建快照）
  - 保留多个 MANIFEST 副本

### 风险 2: SSTable 文件损坏
- **影响：** 部分数据丢失
- **缓解：**
  - Block 级别 CRC32 校验
  - 损坏时跳过该 Table 并记录日志

### 风险 3: WAL 文件损坏
- **影响：** 最后几次写入丢失
- **缓解：**
  - LogEntry 级别 CRC32 校验
  - 损坏时停止重放

### 风险 4: 并发写入时崩溃
- **影响：** 数据不一致
- **缓解：**
  - 使用 Write-Ahead Log 保证原子性
  - 时间戳机制保证顺序

---

## 验收标准

### 功能验收
- [ ] `db.close()` 后重新 `db.open()` 能读取之前写入的数据
- [ ] 崩溃后重启能恢复 WAL 中的数据
- [ ] 多次重启数据一致
- [ ] MANIFEST 文件正确记录 SSTable 变更

### 质量验收
- [ ] 所有单元测试通过
- [ ] 所有集成测试通过
- [ ] 无已知严重 bug
- [ ] 代码覆盖率 ≥ 80%

### 性能验收
- [ ] 恢复时间 < 1s（对于小型数据库）
- [ ] `db.close()` 时间 < 100ms（对于小型数据库）

---

## 参考文档

- [BadgerDB Manifest Implementation](https://github.com/dgraph-io/badger/blob/main/manifest.go)
- [BadgerDB DB Open](https://github.com/dgraph-io/badger/blob/main/db.go)
- [WiscKey Paper](https://www.usenix.org/system/files/conference/fast16/fast16-papers-lu.pdf)

---

**文档版本：** v1.0
**最后更新：** 2026-03-10
**审阅状态：** ✅ 已批准
