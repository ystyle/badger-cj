# DB 持久化功能实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**状态:** ✅ 已完成
**完成日期:** 2026-03-10

**Goal:** 实现 badger-cj 的完整持久化功能，支持 DB.close() 后重启恢复数据

**Architecture:** 
- 新增 ManifestFile 类管理 MANIFEST 文件读写（追加式）
- 修改 DB.open() 实现 MANIFEST 加载、SSTable 加载、WAL 重放
- 修改 DB.close() 实现 MemTable flush 到 SSTable
- 修改 LevelsController 支持从磁盘加载 SSTable

**Tech Stack:** 仓颉语言，std.fs 文件系统，现有 encode/decode 实现

---

## Task 1: 文件路径辅助函数

**Files:**
- Modify: `src/db/helpers.cj`
- Test: `src/db/helpers_test.cj`

### Step 1: 写测试

**创建文件 `src/db/helpers_test.cj`：**

```cangjie
package badgercj.db

import std.test.*

@Test
class HelpersTest {
    @Test
    public func testManifestPath(): Unit {
        let path = manifestPath("/tmp/badger")
        assert(path == "/tmp/badger/MANIFEST")
    }
    
    @Test
    public func testWalPath(): Unit {
        let path = walPath("/tmp/badger", 1)
        assert(path == "/tmp/badger/000001.wal")
        
        let path2 = walPath("/tmp/badger", 123)
        assert(path2 == "/tmp/badger/000123.wal")
    }
    
    @Test
    public func testSstablePath(): Unit {
        let path = sstablePath("/tmp/badger", 1)
        assert(path == "/tmp/badger/000001.sst")
        
        let path2 = sstablePath("/tmp/badger", 456)
        assert(path2 == "/tmp/badger/000456.sst")
    }
}
```

### Step 2: 运行测试（预期失败）

```bash
cjpm test --show-all-output --filter 'HelpersTest.*'
```

Expected: FAIL - 函数未定义

### Step 3: 实现函数

**修改 `src/db/helpers.cj`，添加：**

```cangjie
public func manifestPath(dir: String): String {
    "${dir}/MANIFEST"
}

public func walPath(dir: String, fid: Int64): String {
    let fidStr = fid.toString()
    let padded = if (fidStr.size < 6) {
        "0".repeat(6 - fidStr.size) + fidStr
    } else {
        fidStr
    }
    "${dir}/${padded}.wal"
}

public func sstablePath(dir: String, fid: UInt64): String {
    let fidStr = fid.toString()
    let padded = if (fidStr.size < 6) {
        "0".repeat(6 - fidStr.size) + fidStr
    } else {
        fidStr
    }
    "${dir}/${padded}.sst"
}
```

### Step 4: 运行测试（预期通过）

```bash
cjpm test --show-all-output --filter 'HelpersTest.*'
```

Expected: PASS - 3/3 tests

### Step 5: 提交

```bash
git add src/db/helpers.cj src/db/helpers_test.cj
git commit -m "feat(db): add file path helpers for MANIFEST/WAL/SSTable"
```

---

## Task 2: ManifestFile 类 - 基础结构

**Files:**
- Create: `src/manifest/manifest_file.cj`
- Test: `src/manifest/manifest_file_test.cj`

### Step 1: 写测试

**创建 `src/manifest/manifest_file_test.cj`：**

```cangjie
package badgercj.manifest

import std.test.*
import std.fs.*

@Test
class ManifestFileTest {
    @Test
    public func testOpenEmptyFile(): Unit {
        let dir = "/tmp/badger_test_${System.currentTimeMillis()}"
        Directory.create(Path(dir), recursive: true)
        
        let path = "${dir}/MANIFEST"
        let mf = ManifestFile.open(path)
        
        assert(mf.getManifest().nextFileID == 0)
        assert(mf.getManifest().levels.size == 7)
        
        mf.close()
        cleanupDir(dir)
    }
    
    private func cleanupDir(dir: String): Unit {
        if (exists(Path(dir))) {
            remove(Path(dir), recursive: true)
        }
    }
}
```

### Step 2: 运行测试（预期失败）

```bash
cjpm test --show-all-output --filter 'ManifestFileTest.testOpenEmptyFile'
```

Expected: FAIL - 类未定义

### Step 3: 实现基础结构

**创建 `src/manifest/manifest_file.cj`：**

```cangjie
package badgercj.manifest

import std.fs.*
import std.io.*
import std.collection.*

public class ManifestFile {
    private let path: String
    private var file: ?File
    private var bufferedOut: ?BufferedOutputStream<File>
    private let manifest: Manifest
    
    private init(path: String, manifest: Manifest) {
        this.path = path
        this.file = None
        this.bufferedOut = None
        this.manifest = manifest
    }
    
    public static func open(path: String): ManifestFile {
        let manifest = Manifest()
        let mf = ManifestFile(path, manifest)
        
        let p = Path(path)
        let dir = p.parent
        if (dir.toString() != "" && !exists(dir)) {
            Directory.create(dir, recursive: true)
        }
        
        if (exists(p)) {
            mf.loadFromFile()
        }
        
        let f = File(p, ReadWrite)
        mf.file = f
        mf.bufferedOut = BufferedOutputStream<File>(f, 4096)
        
        return mf
    }
    
    private func loadFromFile(): Unit {
        let f = file ?? throw Exception("File not open")
        f.seek(SeekPosition.Begin(0))
        let len = f.length
        
        if (len == 0) {
            return
        }
        
        let data = Array<Byte>(len, repeat: 0)
        f.read(data)
        
        var offset: Int64 = 0
        while (offset < data.size) {
            let changesetLen = Int64(UInt32(data[offset]) |
                                   (UInt32(data[offset + 1]) << 8) |
                                   (UInt32(data[offset + 2]) << 16) |
                                   (UInt32(data[offset + 3]) << 24))
            offset += 4
            
            let changesetData = data[offset..(offset + changesetLen)]
            let changeset = ManifestChangeSet.decode(changesetData)
            manifest.applyChanges(changeset.changes)
            offset += changesetLen
        }
    }
    
    public func getManifest(): Manifest {
        manifest
    }
    
    public func close(): Unit {
        if (let Some(out) <- bufferedOut) {
            out.flush()
            out.close()
            bufferedOut = None
        }
        file = None
    }
}
```

### Step 4: 运行测试（预期通过）

```bash
cjpm test --show-all-output --filter 'ManifestFileTest.testOpenEmptyFile'
```

Expected: PASS

### Step 5: 提交

```bash
git add src/manifest/manifest_file.cj src/manifest/manifest_file_test.cj
git commit -m "feat(manifest): add ManifestFile class with basic open/close"
```

---

## Task 3: ManifestFile 类 - saveChanges

**Files:**
- Modify: `src/manifest/manifest_file.cj`
- Modify: `src/manifest/manifest_file_test.cj`

### Step 1: 写测试

**在 `src/manifest/manifest_file_test.cj` 添加：**

```cangjie
@Test
public func testSaveAndLoadChanges(): Unit {
    let dir = "/tmp/badger_test_${System.currentTimeMillis()}"
    Directory.create(Path(dir), recursive: true)
    let path = "${dir}/MANIFEST"
    
    // 1. 创建并保存变更
    let mf1 = ManifestFile.open(path)
    let changes = ManifestChangeSet()
    changes.add(ManifestChange(1, ManifestChangeOp.Create, level: 0))
    changes.add(ManifestChange(2, ManifestChangeOp.Create, level: 1))
    mf1.saveChanges(changes)
    mf1.close()
    
    // 2. 重新加载验证
    let mf2 = ManifestFile.open(path)
    let m = mf2.getManifest()
    
    assert(m.levels[0].size == 1)
    assert(m.levels[0][0].id == 1)
    assert(m.levels[1].size == 1)
    assert(m.levels[1][0].id == 2)
    
    mf2.close()
    cleanupDir(dir)
}
```

### Step 2: 运行测试（预期失败）

```bash
cjpm test --show-all-output --filter 'ManifestFileTest.testSaveAndLoadChanges'
```

Expected: FAIL - saveChanges 未实现

### Step 3: 实现 saveChanges

**在 `src/manifest/manifest_file.cj` 添加：**

```cangjie
public func saveChanges(changes: ManifestChangeSet): Unit {
    let encoded = changes.encode()
    
    let out = bufferedOut ?? throw Exception("ManifestFile not open")
    
    // 写入长度（4 bytes LE）
    let len = UInt32(encoded.size)
    out.write(UInt8(len & 0xFF))
    out.write(UInt8((len >> 8) & 0xFF))
    out.write(UInt8((len >> 16) & 0xFF))
    out.write(UInt8((len >> 24) & 0xFF))
    
    // 写入数据
    out.write(encoded)
    out.flush()
    
    // 更新内存中的 manifest
    manifest.applyChanges(changes.changes)
}
```

### Step 4: 运行测试（预期通过）

```bash
cjpm test --show-all-output --filter 'ManifestFileTest.testSaveAndLoadChanges'
```

Expected: PASS

### Step 5: 提交

```bash
git add src/manifest/manifest_file.cj src/manifest/manifest_file_test.cj
git commit -m "feat(manifest): implement ManifestFile.saveChanges()"
```

---

## Task 4: LevelsController - 添加 dir 属性

**Files:**
- Modify: `src/db/levels.cj`
- Test: `src/db/levels_test.cj`

### Step 1: 写测试

**在 `src/db/levels_test.cj` 添加：**

```cangjie
@Test
public func testConstructorWithDir(): Unit {
    let manifest = Manifest()
    let lc = LevelsController(manifest: manifest, dir: "/tmp/test")
    
    assert(lc.getDir() == "/tmp/test")
}
```

### Step 2: 运行测试（预期失败）

```bash
cjpm test --show-all-output --filter 'LevelsControllerTest.testConstructorWithDir'
```

Expected: FAIL - dir 参数未支持

### Step 3: 修改 LevelsController

**修改 `src/db/levels.cj`：**

```cangjie
public class LevelsController {
    private let levels: ArrayList<LevelHandler>
    private let manifest: Manifest
    private let dir: String
    private let nextFileID: UInt64
    
    public init(manifest!: Manifest = Manifest(), dir!: String = "") {
        this.manifest = manifest
        this.dir = dir
        this.nextFileID = manifest.nextFileID
        this.levels = ArrayList<LevelHandler>()
        
        for (i in 0..7) {
            levels.add(LevelHandler(i))
        }
    }
    
    // ... 其他方法保持不变 ...
    
    public func getDir(): String {
        dir
    }
}
```

### Step 4: 运行测试（预期通过）

```bash
cjpm test --show-all-output --filter 'LevelsControllerTest.testConstructorWithDir'
```

Expected: PASS

### Step 5: 提交

```bash
git add src/db/levels.cj src/db/levels_test.cj
git commit -m "feat(db): add dir property to LevelsController"
```

---

## Task 5: LevelsController - loadTables 方法

**Files:**
- Modify: `src/db/levels.cj`
- Modify: `src/db/levels_test.cj`

### Step 1: 写测试

**在 `src/db/levels_test.cj` 添加：**

```cangjie
@Test
public func testLoadTables(): Unit {
    let dir = "/tmp/badger_test_${System.currentTimeMillis()}"
    Directory.create(Path(dir), recursive: true)
    
    // 1. 创建一个 SSTable 文件
    let builder = TableBuilder()
    builder.add([0x61, 0x62], ValueStruct([0x76], version: 1))
    let data = builder.finish()
    
    let tablePath = sstablePath(dir, 1)
    let f = File(Path(tablePath), Write)
    f.write(data)
    f.close()
    
    // 2. 创建 manifest 包含这个 table
    let manifest = Manifest()
    manifest.levels[0].add(TableInfo(1))
    
    // 3. 加载 tables
    let lc = LevelsController(manifest: manifest, dir: dir)
    lc.loadTables()
    
    // 4. 验证
    let handler = lc.getLevelHandler(0)
    assert(handler.numTables() == 1)
    
    cleanupDir(dir)
}

private func cleanupDir(dir: String): Unit {
    if (exists(Path(dir))) {
        remove(Path(dir), recursive: true)
    }
}
```

### Step 2: 运行测试（预期失败）

```bash
cjpm test --show-all-output --filter 'LevelsControllerTest.testLoadTables'
```

Expected: FAIL - loadTables 未实现

### Step 3: 实现 loadTables

**在 `src/db/levels.cj` 添加：**

```cangjie
import std.fs.*
import std.io.*
import badgercj.table.*
import badgercj.db.helpers.*

public func loadTables(): Unit {
    for (level in 0..7) {
        let tables = manifest.levels[level]
        for (tableInfo in tables) {
            let path = sstablePath(dir, tableInfo.id)
            if (exists(Path(path))) {
                let f = File(Path(path), Read)
                let data = Array<Byte>(f.length, repeat: 0)
                f.read(data)
                f.close()
                
                let table = Table(tableInfo.id, data)
                levels[level].addTable(table)
            }
        }
    }
}
```

### Step 4: 运行测试（预期通过）

```bash
cjpm test --show-all-output --filter 'LevelsControllerTest.testLoadTables'
```

Expected: PASS

### Step 5: 提交

```bash
git add src/db/levels.cj src/db/levels_test.cj
git commit -m "feat(db): implement LevelsController.loadTables()"
```

---

## Task 6: MemTable - 添加 isEmpty 和 deleteWAL

**Files:**
- Modify: `src/db/memtable.cj`
- Test: `src/db/memtable_test.cj`

### Step 1: 写测试

**在 `src/db/memtable_test.cj` 添加：**

```cangjie
@Test
public func testIsEmpty(): Unit {
    let opt = DBOptions(Dir: "/tmp/test")
    let mt = MemTable(opt, 1, false)
    
    assert(mt.isEmpty())
    
    mt.put([0x61, 0x62], ValueStruct([0x76], version: 1))
    
    assert(!mt.isEmpty())
}
```

### Step 2: 运行测试（预期失败）

```bash
cjpm test --show-all-output --filter 'MemTableTest.testIsEmpty'
```

Expected: FAIL - isEmpty 未实现

### Step 3: 实现 isEmpty 和 deleteWAL

**在 `src/db/memtable.cj` 添加：**

```cangjie
public func isEmpty(): Bool {
    sl.size() == 0
}

public func deleteWAL(): Unit {
    if (let Some(w) <- wal) {
        w.delete()
        wal = None
    }
}
```

### Step 4: 运行测试（预期通过）

```bash
cjpm test --show-all-output --filter 'MemTableTest.testIsEmpty'
```

Expected: PASS

### Step 5: 提交

```bash
git add src/db/memtable.cj src/db/memtable_test.cj
git commit -m "feat(db): add MemTable.isEmpty() and deleteWAL()"
```

---

## Task 7: DB - 添加 ManifestFile 成员

**Files:**
- Modify: `src/db/db.cj`

### Step 1: 修改 DB 类定义

**修改 `src/db/db.cj`：**

```cangjie
import badgercj.manifest.ManifestFile

public class DB {
    private let opt: DBOptions
    private let manifest: Manifest
    private let manifestFile: ManifestFile  // 新增
    private let lc: LevelsController
    // ... 其他成员保持不变 ...
    
    public init(
        opt: DBOptions,
        mt: MemTable,
        manifest: Manifest,
        manifestFile: ManifestFile,  // 新增参数
        lc: LevelsController,
        vlog: VLogManager
    ) {
        this.opt = opt
        this.mt = mt
        this.manifest = manifest
        this.manifestFile = manifestFile  // 新增
        this.lc = lc
        // ... 其他初始化保持不变 ...
    }
}
```

### Step 2: 提交

```bash
git add src/db/db.cj
git commit -m "refactor(db): add manifestFile member to DB class"
```

---

## Task 8: DB.open() - 实现恢复逻辑

**Files:**
- Modify: `src/db/db.cj`
- Test: `src/db/db_test.cj`

### Step 1: 写测试

**在 `src/db/db_test.cj` 添加：**

```cangjie
@Test
public func testOpenRecovery(): Unit {
    let dir = "/tmp/badger_test_${System.currentTimeMillis()}"
    Directory.create(Path(dir), recursive: true)
    
    // 1. 创建 DB 并写入数据
    let db1 = DB.open(DBOptions(Dir: dir))
    db1.set("key1", "value1")
    db1.set("key2", "value2")
    db1.close()
    
    // 2. 重新打开验证恢复
    let db2 = DB.open(DBOptions(Dir: dir))
    
    let v1 = db2.get("key1")
    assert(v1 == Some(ValueStruct("value1", version: 1)))
    
    let v2 = db2.get("key2")
    assert(v2 == Some(ValueStruct("value2", version: 2)))
    
    db2.close()
    
    // 清理
    if (exists(Path(dir))) {
        remove(Path(dir), recursive: true)
    }
}
```

### Step 2: 运行测试（预期失败）

```bash
cjpm test --show-all-output --filter 'DBTest.testOpenRecovery'
```

Expected: FAIL - DB.open 未实现恢复逻辑

### Step 3: 修改 DB.open()

**修改 `src/db/db.cj` 的 open 方法：**

```cangjie
import badgercj.db.helpers.*

public static func open(opt: DBOptions): DB {
    if (!exists(Path(opt.Dir))) {
        Directory.create(Path(opt.Dir), recursive: true)
    }
    
    // 1. 加载 MANIFEST
    let manifestPath = manifestPath(opt.Dir)
    let manifestFile = ManifestFile.open(manifestPath)
    let manifest = manifestFile.getManifest()
    
    // 2. 从 MANIFEST 恢复 LevelsController
    let lc = LevelsController(manifest: manifest, dir: opt.Dir)
    lc.loadTables()
    
    // 3. 恢复 MemTable (重放 WAL)
    let fid = Int64(manifest.nextFileID)
    let mt = MemTable(opt, fid, false)
    let walPath = walPath(opt.Dir, fid)
    if (exists(Path(walPath))) {
        let wal = WAL.open(walPath)
        wal.replay(mt)
        wal.close()
    }
    
    // 4. 创建 DB 实例
    let vlog = VLogManager(Path(opt.Dir))
    let db = DB(opt, mt, manifest, manifestFile, lc, vlog)
    db.running = AtomicBool(true)
    let fut = spawn { db.flushLoop() }
    db.flushFut = Some(fut)
    return db
}
```

### Step 4: 运行测试（预期失败）

```bash
cjpm test --show-all-output --filter 'DBTest.testOpenRecovery'
```

Expected: FAIL - DB.close() 未实现 flush

### Step 5: 提交

```bash
git add src/db/db.cj src/db/db_test.cj
git commit -m "feat(db): implement DB.open() recovery logic"
```

---

## Task 9: DB.close() - 实现 flush 和持久化

**Files:**
- Modify: `src/db/db.cj`

### Step 1: 实现 flushMemTableToDisk

**在 `src/db/db.cj` 添加私有方法：**

```cangjie
import badgercj.table.*
import badgercj.db.helpers.*

private func flushMemTableToDisk(mt: MemTable): ManifestChangeSet {
    // 1. 构建 SSTable
    let builder = TableBuilder()
    let iter = mt.iterator()
    while (iter.hasNext()) {
        if (let Some(e) <- iter.next()) {
            let (key, vs) = e
            builder.add(key, vs)
        }
    }
    let data = builder.finish()
    
    // 2. 写入文件
    let tableID = nextFileID.fetchAdd(1)
    let path = sstablePath(opt.Dir, tableID)
    let f = File(Path(path), Write)
    f.write(data)
    f.close()
    
    // 3. 添加到 LevelsController
    let table = Table(tableID, data)
    lc.addTable(0, table)
    
    // 4. 返回 ManifestChange
    let changes = ManifestChangeSet()
    changes.add(ManifestChange(tableID, ManifestChangeOp.Create, level: 0))
    return changes
}
```

### Step 2: 修改 DB.close()

**修改 `src/db/db.cj` 的 close 方法：**

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
            let changes = flushMemTableToDisk(mt)
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
```

### Step 3: 运行测试（预期通过）

```bash
cjpm test --show-all-output --filter 'DBTest.testOpenRecovery'
```

Expected: PASS

### Step 4: 提交

```bash
git add src/db/db.cj
git commit -m "feat(db): implement DB.close() flush and persistence"
```

---

## Task 10: 持久化集成测试

**Files:**
- Create: `src/db/persistence_test.cj`

### Step 1: 创建集成测试文件

**创建 `src/db/persistence_test.cj`：**

```cangjie
package badgercj.db

import std.test.*
import std.fs.*

@Test
class PersistenceTest {
    @Test
    public func testBasicPersistence(): Unit {
        let dir = "/tmp/badger_persistence_test_${System.currentTimeMillis()}"
        Directory.create(Path(dir), recursive: true)
        
        // 1. 创建 DB 并写入数据
        let db1 = DB.open(DBOptions(Dir: dir))
        db1.set("key1", "value1")
        db1.set("key2", "value2")
        db1.close()
        
        // 2. 重新打开 DB
        let db2 = DB.open(DBOptions(Dir: dir))
        
        // 3. 验证数据
        let v1 = db2.get("key1")
        assert(v1 != None)
        
        let v2 = db2.get("key2")
        assert(v2 != None)
        
        db2.close()
        cleanupDir(dir)
    }
    
    @Test
    public func testCrashRecovery(): Unit {
        let dir = "/tmp/badger_persistence_test_${System.currentTimeMillis()}"
        Directory.create(Path(dir), recursive: true)
        
        // 1. 创建 DB 并写入数据
        let db1 = DB.open(DBOptions(Dir: dir))
        db1.set("key1", "value1")
        // 不调用 close，模拟崩溃
        
        // 2. 重新打开 DB（应该从 WAL 恢复）
        let db2 = DB.open(DBOptions(Dir: dir))
        
        // 3. 验证 WAL 恢复
        let v1 = db2.get("key1")
        assert(v1 != None)
        
        db2.close()
        cleanupDir(dir)
    }
    
    @Test
    public func testMultipleRestarts(): Unit {
        let dir = "/tmp/badger_persistence_test_${System.currentTimeMillis()}"
        Directory.create(Path(dir), recursive: true)
        
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
        
        let v1 = db3.get("key1")
        assert(v1 != None)
        
        let v2 = db3.get("key2")
        assert(v2 != None)
        
        db3.close()
        cleanupDir(dir)
    }
    
    @Test
    public func testLargeDataPersistence(): Unit {
        let dir = "/tmp/badger_persistence_test_${System.currentTimeMillis()}"
        Directory.create(Path(dir), recursive: true)
        
        // 1. 写入大量数据
        let db1 = DB.open(DBOptions(Dir: dir))
        for (i in 0..100) {
            db1.set("key${i}", "value${i}")
        }
        db1.close()
        
        // 2. 重新打开验证
        let db2 = DB.open(DBOptions(Dir: dir))
        
        var count = 0
        for (i in 0..100) {
            if (db2.get("key${i}") != None) {
                count++
            }
        }
        
        assert(count == 100)
        db2.close()
        cleanupDir(dir)
    }
    
    private func cleanupDir(dir: String): Unit {
        if (exists(Path(dir))) {
            remove(Path(dir), recursive: true)
        }
    }
}
```

### Step 2: 运行测试

```bash
cjpm test --show-all-output --filter 'PersistenceTest.*'
```

Expected: PASS - 4/4 tests

### Step 3: 提交

```bash
git add src/db/persistence_test.cj
git commit -m "test(db): add persistence integration tests"
```

---

## Task 11: 运行所有测试

### Step 1: 运行完整测试套件

```bash
cjpm test
```

Expected: 所有测试通过

### Step 2: 提交进度更新

**修改 `docs/progress-tracking.md`：**

```markdown
### Phase 6 P1: 持久化功能 ✅ 已完成

| 任务 | 预估 | 状态 | 说明 |
|------|------|------|------|
| 文件路径辅助函数 | 1h | ✅ | manifestPath/walPath/sstablePath |
| ManifestFile 类 | 4h | ✅ | 追加式 MANIFEST 管理 |
| LevelsController.loadTables | 2h | ✅ | SSTable 文件加载 |
| MemTable.isEmpty/deleteWAL | 1h | ✅ | 持久化辅助方法 |
| DB.open() 恢复逻辑 | 3h | ✅ | MANIFEST/SSTable/WAL 恢复 |
| DB.close() 持久化 | 3h | ✅ | flush MemTable 到 SSTable |
| 集成测试 | 2h | ✅ | 生命周期/崩溃恢复测试 |

**总测试数：** 162
**通过率：** 100% ✅
```

### Step 3: 提交

```bash
git add docs/progress-tracking.md
git commit -m "docs: update progress for Phase 6 P1 persistence"
```

---

## 完成检查清单

- [ ] Task 1: 文件路径辅助函数
- [ ] Task 2: ManifestFile 基础结构
- [ ] Task 3: ManifestFile.saveChanges
- [ ] Task 4: LevelsController.dir
- [ ] Task 5: LevelsController.loadTables
- [ ] Task 6: MemTable.isEmpty/deleteWAL
- [ ] Task 7: DB.manifestFile
- [ ] Task 8: DB.open() 恢复
- [ ] Task 9: DB.close() 持久化
- [ ] Task 10: 集成测试
- [ ] Task 11: 完整测试 + 文档更新

---

**计划版本：** v1.0
**创建日期：** 2026-03-10
**预估总时间：** ~15h
