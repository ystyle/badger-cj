# badger-cj InMemory 模式实现计划

## 1. 概述

### 1.1 目标

为 badger-cj 添加纯内存模式，适用于：
- 单元测试（无需清理文件）
- 临时缓存（不需要持久化）
- 性能测试（无磁盘 I/O）

### 1.2 Go 版本参考

```go
// Go badger 使用方式
opt := badger.DefaultOptions("").
    WithInMemory(true)
db, _ := badger.Open(opt)
```

关键行为：
- 不创建任何目录/文件
- 不获取文件锁
- ValueThreshold 设为 MaxInt32（所有数据进 LSM）
- VLog GC 不运行
- SSTable 使用 `OpenInMemoryTable` 从内存数据创建

## 2. 设计方案

### 2.1 架构

```
┌─────────────────────────────────────────────────────────┐
│                     Badger.open()                        │
│                           │                              │
│                 ┌─────────┴─────────┐                   │
│                 │ InMemory?         │                   │
│                 └─────────┬─────────┘                   │
│                    Yes │        │ No                     │
│                        ▼        ▼                        │
│              ┌──────────┐  ┌──────────┐                 │
│              │ 内存模式  │  │ 持久化   │                 │
│              │          │  │ 模式     │                 │
│              │ - 无目录  │  │ - 创建目录│                 │
│              │ - 无WAL  │  │ - WAL    │                 │
│              │ - 无VLog │  │ - VLog   │                 │
│              │ - 内存表 │  │ - 文件表 │                 │
│              └──────────┘  └──────────┘                 │
└─────────────────────────────────────────────────────────┘
```

### 2.2 关键决策

| 组件 | InMemory 模式行为 |
|------|------------------|
| 目录创建 | 跳过 |
| 文件锁 | 跳过 |
| WAL | 自动禁用 |
| VLog | 自动禁用（ValueThreshold = MaxInt32） |
| VLog GC | 不启动 |
| MANIFEST | 使用内存结构，不写文件 |
| SSTable | 从内存数据创建，不写磁盘 |
| Compaction | 在内存中进行（L0 内存表） |

### 2.3 数据流

```
InMemory 写入流程:

  set(key, value)
       │
       ▼
  ┌─────────────┐
  │  MemTable   │
  │  (内存)      │
  └──────┬──────┘
         │ flush
         ▼
  ┌─────────────┐
  │ TableBuilder│
  │ .finish()   │
  └──────┬──────┘
         │ data: Array<Byte>
         ▼
  ┌─────────────┐
  │ Table(内存) │  ← 直接从 data 创建，不写文件
  │ L0 内存表   │
  └─────────────┘
```

## 3. 实现细节

### 3.1 Config 添加 InMemory 字段

```cangjie
// src/db/config.cj
public class Config {
    public let Dir: String
    public let MemTableSize: UInt64
    public let ValueThreshold: UInt64
    public let MaxLevels: Int
    public let NumLevelZeroTables: Int
    public let DisableWAL: Bool
    public let DetectConflicts: Bool
    public let BloomFalsePositive: Float64
    public let UseIoUring: Bool
    public let InMemory: Bool  // 新增

    public init(
        dir!: String = "",
        memTableSize!: UInt64 = 64 * 1024 * 1024u64,
        valueThreshold!: UInt64 = 1 * 1024 * 1024u64,
        maxLevels!: Int = 7,
        numLevelZeroTables!: Int = 4,
        disableWAL!: Bool = false,
        detectConflicts!: Bool = true,
        bloomFalsePositive!: Float64 = 0.01,
        useIoUring!: Bool = true,
        inMemory!: Bool = false  // 新增
    ) {
        // InMemory 模式验证
        if (inMemory && dir != "") {
            throw BadgerException.configError("Cannot use InMemory mode with Dir set")
        }
        
        this.Dir = dir
        this.MemTableSize = memTableSize
        // InMemory 模式：ValueThreshold 设为最大值，所有数据进 LSM
        if (inMemory) {
            this.ValueThreshold = UInt64.MaxValue
        } else {
            this.ValueThreshold = valueThreshold
        }
        this.MaxLevels = maxLevels
        this.NumLevelZeroTables = numLevelZeroTables
        // InMemory 模式：自动禁用 WAL
        this.DisableWAL = inMemory || disableWAL
        this.DetectConflicts = detectConflicts
        this.BloomFalsePositive = bloomFalsePositive
        this.UseIoUring = useIoUring
        this.InMemory = inMemory
    }
    
    public func withInMemory(inMemory: Bool): Config {
        Config(
            dir: this.Dir,
            memTableSize: this.MemTableSize,
            valueThreshold: this.ValueThreshold,
            maxLevels: this.MaxLevels,
            numLevelZeroTables: this.NumLevelZeroTables,
            disableWAL: this.DisableWAL,
            detectConflicts: this.DetectConflicts,
            bloomFalsePositive: this.BloomFalsePositive,
            useIoUring: this.UseIoUring,
            inMemory: inMemory
        )
    }
    
    // 其他 with* 方法也需要添加 inMemory 参数
}
```

### 3.2 Badger.open() 修改

```cangjie
// src/db/badger.cj
public static func open(opt: Config): Badger {
    // InMemory 模式验证
    if (opt.InMemory && opt.Dir != "") {
        throw BadgerException.configError("Cannot use InMemory mode with Dir set")
    }
    
    // 跳过目录创建（InMemory 模式）
    if (!opt.InMemory && !exists(Path(opt.Dir))) {
        Directory.create(Path(opt.Dir), recursive: true)
    }
    
    // MANIFEST：InMemory 模式使用空路径
    let manifestPath = opt.InMemory ? "" : manifestPath(opt.Dir)
    let manifestFile = opt.InMemory ? ManifestFile.memory() : ManifestFile.open(manifestPath)
    
    let manifest = manifestFile.getManifest()
    
    let lc = LevelsController(manifest: manifest, dir: opt.Dir, inMemory: opt.InMemory)
    if (!opt.InMemory) {
        lc.loadTables()  // InMemory 模式不加载文件
    }
    
    // ... 其余初始化
}
```

### 3.3 Table 添加 isInMemory 标记

```cangjie
// src/table/table.cj
protected class Table {
    private let data: Array<Byte>
    public let id: UInt64
    public let isInMemory: Bool  // 新增
    private let index: TableIndex
    // ...
    
    public init(id: UInt64, data: Array<Byte>, inMemory!: Bool = false) {
        this.id = id
        this.data = data
        this.isInMemory = inMemory
        // ... 其余初始化
    }
    
    // 工厂方法：创建内存表
    public static func fromMemory(id: UInt64, data: Array<Byte>): Table {
        Table(id: id, data: data, inMemory: true)
    }
}
```

### 3.4 LevelsController 支持内存模式

```cangjie
// src/db/levels.cj
protected class LevelsController {
    private let levels: ArrayList<LevelHandler>
    private let manifest: Manifest
    private let dir: String
    private let nextFileID: UInt64
    private let cstatus: compactStatus
    private let inMemory: Bool  // 新增
    private let memoryTables: HashMap<UInt64, Array<Byte>>  // 新增：内存表数据存储
    
    public init(manifest: Manifest, dir: String, inMemory!: Bool = false) {
        this.inMemory = inMemory
        this.dir = dir
        this.memoryTables = HashMap<UInt64, Array<Byte>>()
        // ...
    }
    
    // InMemory 模式：将表数据保存到内存
    public func addMemoryTable(id: UInt64, data: Array<Byte>): Unit {
        if (inMemory) {
            memoryTables[id] = data
        }
        let table = Table.fromMemory(id, data)
        levels[0].addTable(table)
    }
}
```

### 3.5 MemTable.flush() 修改

```cangjie
// src/db/memtable.cj - flush 到 SSTable 的逻辑
// 需要在 Badger 层面控制

// src/db/badger.cj
private func flushMemTableToL0(mt: MemTable): Unit {
    let builder = TableBuilder()
    // ... 构建表
    
    let data = builder.finish()
    let fid = nextFileID()
    
    if (opt.InMemory) {
        // InMemory 模式：直接创建内存表
        lc.addMemoryTable(fid, data)
    } else {
        // 持久化模式：写文件
        let path = sstablePath(opt.Dir, fid)
        writeFile(path, data)
        let table = Table(id: fid, data: data)
        lc.getLevelHandler(0).addTable(table)
    }
}
```

### 3.6 VLog 跳过（InMemory 模式）

```cangjie
// src/db/badger.cj
// ValueThreshold = MaxInt32 时，所有值都会存入 LSM
// VLog 相关逻辑会自动跳过

public func getVS(key: Array<Byte>): ?ValueStruct {
    // ... 从 MemTable 或 SSTable 获取
    // InMemory 模式下，ValueThreshold = MaxInt32
    // 不会有 ValuePointer，值直接存在 LSM 中
}
```

### 3.7 close() 清理

```cangjie
// src/db/badger.cj
public func close(): Unit {
    if (opt.InMemory) {
        // InMemory 模式：不需要刷盘、释放文件锁等
        running.store(false)
        // 停止后台任务
        // 清理内存
        return
    }
    
    // 持久化模式：原有逻辑
    // ...
}
```

## 4. 修改文件清单

| 文件 | 修改内容 | 优先级 |
|------|---------|--------|
| `src/db/config.cj` | 添加 InMemory 字段、withInMemory 方法 | P0 |
| `src/db/badger.cj` | open() 条件判断、close() 条件判断、flush 逻辑 | P0 |
| `src/table/table.cj` | 添加 isInMemory 字段、fromMemory 工厂方法 | P0 |
| `src/db/levels.cj` | 添加 inMemory 字段、addMemoryTable 方法 | P0 |
| `src/db/level_handler.cj` | 支持内存表 | P1 |
| `src/db/compaction.cj` | InMemory 模式下的 compact 逻辑 | P1 |
| `src/db/wal.cj` | InMemory 模式跳过 WAL（已通过 DisableWAL=true 处理） | - |
| `src/vlog/*.cj` | InMemory 模式跳过 VLog（已通过 ValueThreshold=Max 处理） | - |
| `src/manifest/manifest_file.cj` | 添加 memory() 工厂方法（可选） | P2 |
| `src/db/inmemory_test.cj` | 新增测试文件 | P0 |

## 5. 测试用例

### 5.1 基本测试

```cangjie
// src/db/inmemory_test.cj
@Test
class InMemoryTest {
    
    @TestCase
    func testBasicSetGet(): Unit {
        let opt = Config(inMemory: true)
        let db = Badger.open(opt)
        defer { db.close() }
        
        db.update({ txn =>
            txn.set("key".toArray(), "value".toArray())
        })
        
        if (let Some(vs) <- db.get("key".toArray())) {
            @Assert(String.fromUtf8(vs.value) == "value")
        } else {
            @Fail("Should find key")
        }
    }
    
    @TestCase
    func testNoDirCreated(): Unit {
        let opt = Config(inMemory: true)
        let db = Badger.open(opt)
        defer { db.close() }
        
        // 不应该创建任何目录
        @Assert(!exists(Path("/tmp/inmemory_test")))
    }
    
    @TestCase
    func testTransaction(): Unit {
        let opt = Config(inMemory: true)
        let db = Badger.open(opt)
        defer { db.close() }
        
        db.update({ txn =>
            txn.set("k1".toArray(), "v1".toArray())
            txn.set("k2".toArray(), "v2".toArray())
        })
        
        db.view({ txn =>
            @Assert(txn.get("k1".toArray()).isSome())
            @Assert(txn.get("k2".toArray()).isSome())
        })
    }
    
    @TestCase
    func testIterator(): Unit {
        let opt = Config(inMemory: true)
        let db = Badger.open(opt)
        defer { db.close() }
        
        db.update({ txn =>
            txn.set("a".toArray(), "1".toArray())
            txn.set("b".toArray(), "2".toArray())
            txn.set("c".toArray(), "3".toArray())
        })
        
        var count = 0
        db.view({ txn =>
            let iter = txn.newIterator()
            iter.rewind()
            while (iter.valid()) {
                count++
                iter.next()
            }
        })
        
        @Assert(count == 3)
    }
    
    @TestCase
    func testFlushAndRead(): Unit {
        let opt = Config(inMemory: true, memTableSize: 1024u64)
        let db = Badger.open(opt)
        defer { db.close() }
        
        // 写入超过 MemTable 大小，触发 flush
        for (i in 0..100) {
            db.update({ txn =>
                txn.set("key${i}".toArray(), "value${i}".toArray())
            })
        }
        
        // 验证数据仍可读取
        for (i in 0..100) {
            if (let Some(vs) <- db.get("key${i}".toArray())) {
                @Assert(String.fromUtf8(vs.value) == "value${i}")
            } else {
                @Fail("Should find key${i}")
            }
        }
    }
    
    @TestCase
    func testInMemoryWithDirFails(): Unit {
        // InMemory 模式不能设置 Dir
        try {
            let opt = Config(dir: "/tmp/test", inMemory: true)
            @Fail("Should throw exception")
        } catch (e: BadgerException) {
            @Assert(e.code == ErrorCode.InvalidConfig)
        }
    }
}
```

### 5.2 性能对比测试

```cangjie
@TestCase
func testInMemoryVsDiskPerformance(): Unit {
    let keys = 1000
    
    // InMemory 模式
    let opt1 = Config(inMemory: true)
    let db1 = Badger.open(opt1)
    let start1 = DateTime.now().toUnixMillis()
    for (i in 0..keys) {
        db1.update({ txn =>
            txn.set("key${i}".toArray(), "value${i}".toArray())
        })
    }
    let elapsed1 = DateTime.now().toUnixMillis() - start1
    db1.close()
    
    // 持久化模式
    let opt2 = Config(dir: "/tmp/badger_disk_test")
    let db2 = Badger.open(opt2)
    let start2 = DateTime.now().toUnixMillis()
    for (i in 0..keys) {
        db2.update({ txn =>
            txn.set("key${i}".toArray(), "value${i}".toArray())
        })
    }
    let elapsed2 = DateTime.now().toUnixMillis() - start2
    db2.close()
    
    println("InMemory: ${elapsed1}ms, Disk: ${elapsed2}ms")
    // 预期：InMemory 应该更快
}
```

## 6. 实现路线

### Phase 1: 核心功能（1-2 天）
- [ ] Config 添加 InMemory 字段
- [ ] Badger.open() 条件判断
- [ ] Table 添加 isInMemory 标记
- [ ] LevelsController 支持内存表
- [ ] 基本测试通过

### Phase 2: Flush 和 Compaction（1 天）
- [ ] flushMemTableToL0 内存模式支持
- [ ] Compaction 内存模式适配
- [ ] flush 测试通过

### Phase 3: 边缘情况和优化（1 天）
- [ ] close() 清理逻辑
- [ ] 边缘情况测试
- [ ] 性能对比测试
- [ ] 文档更新

## 7. 风险与注意事项

### 7.1 已知限制

1. **数据不持久化**：关闭后数据丢失
2. **内存限制**：大量数据可能 OOM
3. **无崩溃恢复**：进程崩溃数据丢失

### 7.2 兼容性

- InMemory 模式下调用 `Backup()` 应该抛出异常或返回空
- InMemory 模式下调用 `Restore()` 应该抛出异常
- InMemory 模式下调用 `runVLogGC()` 应该直接返回 false

### 7.3 测试策略

- 每个功能测试同时覆盖 InMemory 和持久化模式
- 添加 `@TestCase(inMemory: true)` 参数化测试（如果框架支持）
- 性能测试对比两种模式

## 8. 使用示例

```cangjie
// 单元测试中使用
@Test
func testMyFeature(): Unit {
    let opt = Config(inMemory: true)
    let db = Badger.open(opt)
    defer { db.close() }
    
    // 测试代码...
}

// 临时缓存
let cache = Badger.open(Config(inMemory: true))
cache.update({ txn =>
    txn.set("session:123".toArray(), sessionData.toArray())
})

// 性能测试
let benchDb = Badger.open(Config(inMemory: true))
```

## 9. 参考

- [Go BadgerDB InMemory 模式](https://github.com/dgraph-io/badger/blob/main/db.go)
- [OpenInMemoryTable](https://github.com/dgraph-io/badger/blob/main/table/table.go)