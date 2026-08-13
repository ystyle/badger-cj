# badger-cj

一个可嵌入、持久化且速度很快的基于LSM-Tree的键值 (KV) 数据库，移植自 Go [BadgerDB v4](https://github.com/dgraph-io/badger)。

> ⚠️ **兼容性声明**
> 
> 本项目**不保证**与 Go BadgerDB 的数据文件完全兼容。虽然我们按照 Go 版本的格式实现了 SSTable/VLog/MANIFEST，但由于 Protobuf/FlatBuffers 编码是手动实现，未经充分验证。
> 
> - ✅ **API 语义兼容** - 接口设计遵循 Go 版本
> - ⚠️ **数据格式理论上兼容** - 但未经跨语言测试验证
> - ❌ **不支持直接迁移** - 不能直接读取 Go BadgerDB 的数据目录

## 安装

在 `cjpm.toml` 中添加依赖：

```toml
[dependencies]
  "badgercj" = "1.2.0" # 注意使用最新的版本
```

## 快速开始

```cangjie
import badgercj.db.*

main() {
    // 1. 打开数据库
    let opt = Config(dir: "/tmp/mydb")
    let db = Badger.open(opt)
    
    // 2. 写入数据（使用事务）
    db.update({ txn =>
        txn.set("name".toArray(), "badger-cj".toArray())
    })
    
    // 3. 读取数据
    if (let Some(vs) <- db.get("name".toArray())) {
        println("value: ${String.fromUtf8(vs.value)}")
    }
    
    // 4. 关闭数据库
    db.close()
}
```

## 基本操作

### 打开/关闭数据库

```cangjie
// 方式 1：直接配置
let opt = Config(
    dir: "/tmp/mydb",                      // 数据目录
    memTableSize: 64 * 1024 * 1024u64,     // MemTable 大小 (默认 64MB)
    numLevelZeroTables: 4,                 // L0 表数量阈值
)
let db = Badger.open(opt)

// 方式 2：链式配置（推荐）
let opt2 = Config()
    .withDir("/tmp/mydb")
    .withMemTableSize(128 * 1024 * 1024u64)
    .withDisableWAL(false)

// 方式 3：纯内存模式（适合测试、临时缓存）
let opt3 = Config(inMemory: true)
let db3 = Badger.open(opt3)

// 使用完毕后关闭
db.close()
```

**可用的 with* 方法：**

| 方法 | 说明 |
|------|------|
| `withDir(dir)` | 数据目录 |
| `withMemTableSize(size)` | MemTable 大小 |
| `withValueThreshold(t)` | VLog 阈值 |
| `withMaxLevels(n)` | LSM 层数 |
| `withNumLevelZeroTables(n)` | L0 表数量阈值 |
| `withDisableWAL(bool)` | 禁用 WAL |
| `withDetectConflicts(bool)` | 冲突检测 |
| `withInMemory(bool)` | 纯内存模式 |
| `withCompression(type)` | 压缩类型（None/Snappy） |
| `withAutoCloseOnExit(bool)` | 进程退出时自动关闭（默认 false） |

### 进程退出时自动关闭

对于服务器应用，`close()` 可能没有合适的调用位置。`Config.AutoCloseOnExit` 可以在进程退出时自动关闭数据库。

```cangjie
// 启用自动关闭
let opt = Config(dir: "./data")
    .withAutoCloseOnExit(true)
let db = Badger.open(opt)

// 服务器运行...
server.listen()  // 阻塞，没有地方调用 db.close()

// 进程退出时自动调用 db.close()
```

**注意事项：**
- 默认关闭，需要手动启用
- `close()` 是幂等的，多次调用安全
- 不影响 `kill -9` 等强制终止（数据依赖 WAL 恢复）

**手动使用 atExit：**

如果不启用 `AutoCloseOnExit`，可以手动注册：

```cangjie
import std.env.atExit

let db = Badger.open(Config(dir: "./data"))

// 手动注册退出回调
atExit() {
    db.close()
}

// 或者使用 Holder 模式管理多个资源
class DbHolder {
    private var db: ?Badger = None
    private var closed = false
    
    public func set(d: Badger): Unit { db = Some(d) }
    
    public func close(): Unit {
        if (closed) { return }
        closed = true
        match (db) {
            case Some(d) => d.close()
            case _ => ()
        }
    }
}

let holder = DbHolder()
holder.set(db)
atExit() { holder.close() }
```

### InMemory 模式

纯内存模式，不写入磁盘，适合：
- 单元测试（无需清理文件）
- 临时缓存
- 性能测试

```cangjie
// 创建内存数据库
let db = Badger.open(Config(inMemory: true, memTableSize: 64 * 1024u64))

// 使用方式与普通数据库相同
db.update({ txn =>
    txn.set("key".toArray(), "value".toArray())
})

db.close()  // 关闭后数据丢失
```

**特点：**
- 不创建任何目录/文件
- WAL 自动禁用
- VLog 自动禁用（所有数据进 LSM）
- Compaction 跳过
- 关闭后数据丢失

### 数据库状态与信息

```cangjie
// 检查是否已关闭
if (db.isClosed()) {
    println("database is closed")
}

// 同步数据到磁盘
db.sync()

// 获取存储大小
let size = db.size()
println("LSM: ${size.LSM} bytes, VLog: ${size.VLog} bytes")

// 获取所有 SSTable 信息
let tables = db.tables()
for (t in tables) {
    println("Table ${t.ID}: level=${t.Level}, keys=${t.KeyCount}")
}

// 获取所有 Level 信息
let levels = db.levels()
for (l in levels) {
    println("Level ${l.Level}: ${l.NumTables} tables, ${l.Size} bytes")
}
```

### 读写数据

```cangjie
// 写入 - 使用事务
db.update({ txn =>
    txn.set("key".toArray(), "value".toArray())
})

// 读取
if (let Some(vs) <- db.get("key".toArray())) {
    println("${String.fromUtf8(vs.value)}")  // Array<Byte>
}

// 删除 - 使用事务
db.update({ txn =>
    txn.delete("key".toArray())
})
```

## 事务

### 推荐方式（自动管理）

```cangjie
// 读写事务 - 自动 commit/rollback
db.update({ txn =>
    txn.set("key".toArray(), "value".toArray())
    txn.delete("old-key".toArray())
    
    // 读取自己写入的数据 (read-your-writes)
    if (let Some(val) <- txn.get("key".toArray())) {
        println("value: ${String.fromUtf8(val)}")
    }
})

// 只读事务
db.view({ txn =>
    if (let Some(val) <- txn.get("key".toArray())) {
        println("value: ${String.fromUtf8(val)}")
    }
})
```

### 手动管理

```cangjie
let txn = db.newTransaction(update: true)
try {
    txn.set("key".toArray(), "value".toArray())
    txn.commit()
} finally {
    txn.discard()
}
```

### 批量写入

```cangjie
// 同步批量写入
let entries = ArrayList<Entry>()
entries.add(Entry.new("key1".toArray(), "value1".toArray()))
entries.add(Entry.new("key2".toArray(), "value2".toArray()))
db.batchSet(entries)

// 异步批量写入
db.batchSetAsync(entries, callback: { =>
    println("batch write completed")
})
```

## TTL 过期

```cangjie
import std.time.*

// 设置 TTL（24小时后过期）
let entry = Entry.new("session".toArray(), "data".toArray())
    .withTTL(Duration.hour * 24)
db.batchSet(ArrayList<Entry>([entry]))

// 过期数据读取返回 None
if (db.get("session".toArray()).isNone()) {
    println("session expired")
}
```

## 用户自定义元数据

```cangjie
// 设置 userMeta（用户自定义标记）
let entry = Entry.new("key".toArray(), "value".toArray())
    .withMeta(0x42)  // 用户可设置任意值
    .withTTL(Duration.hour)
db.batchSet(ArrayList<Entry>([entry]))

// 读取时获取 userMeta
db.view({ txn =>
    let iter = txn.newIterator()
    iter.rewind()
    if (iter.valid()) {
        let item = iter.item()
        println("userMeta: ${item.userMeta}")  // 0x42
    }
})
```

## 迭代器

### 遍历所有 key

```cangjie
db.view({ txn =>
    let iter = txn.newIterator(opt: IteratorOptions())
    iter.rewind()
    while (iter.valid()) {
        let item = iter.item()
        println("key: ${String.fromUtf8(item.key())}")
        iter.next()
    }
})
```

### 前缀扫描

```cangjie
// 方式 1：使用 for-in（推荐，代码简洁）
let prefix = "user:".toArray()
for (item in db.scan(prefix)) {
    println("${String.fromUtf8(item.key)} = ${String.fromUtf8(item.value)}")
}

// 方式 2：使用 IteratorOptions.prefix
db.view({ txn =>
    let opt = IteratorOptions(prefix: "user:".toArray())
    let iter = txn.newIterator(opt: opt)
    iter.rewind()
    while (iter.valid()) {
        let item = iter.item()
        println("${String.fromUtf8(item.key())} = ${String.fromUtf8(item.value())}")
        iter.next()
    }
})

// 方式 3：使用 validForPrefix（更灵活）
db.view({ txn =>
    let iter = txn.newIterator()
    let prefix = "user:".toArray()
    iter.seek(prefix)  // 先定位到前缀开头
    while (iter.validForPrefix(prefix)) {
        let item = iter.item()
        println("${String.fromUtf8(item.key())}")
        iter.next()
    }
})
```

### 反向遍历

```cangjie
db.view({ txn =>
    let opt = IteratorOptions(reverse: true)
    let iter = txn.newIterator(opt: opt)
    iter.rewind()
    while (iter.valid()) {
        let item = iter.item()
        println("${String.fromUtf8(item.key())}")
        iter.next()
    }
})
```

## 快照

```cangjie
// 创建快照
let snapshot = db.newSnapshot()

// 快照读取（一致性视图）
if (let Some(item) <- snapshot.get("key".toArray())) {
    println("value: ${String.fromUtf8(item.value())}")
}

// 快照迭代器
let iter = snapshot.newIterator(opt: IteratorOptions())
// ... 使用迭代器

// 释放快照
snapshot.close()
```

## Compaction

```cangjie
// 手动触发 Compaction
db.compact()

// 刷新 MemTable 到 SSTable
db.flushMemTable()
```

## Stream API

用于大规模并发数据处理：

```cangjie
import std.sync.*

// 基本用法：遍历所有 KV
let count = AtomicInt64(0)
let stream = Stream(db)
stream.send = { kvs =>
    count.fetchAdd(kvs.size)
}
stream.orchestrate()
println("Total keys: ${count.load()}")

// 前缀过滤
let stream2 = Stream(db)
stream2.prefix = "user:".toArray()
stream2.send = { kvs =>
    for (kv in kvs) {
        println("key: ${String.fromUtf8(kv.key)}")
    }
}
stream2.orchestrate()

// 自定义并发数（默认 8）
let stream3 = Stream(db)
stream3.numSpawn = 16
stream3.send = { kvs => /* 处理 */ }
stream3.orchestrate()
```

**Stream 配置项：**

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `prefix` | [] | 前缀过滤 |
| `numSpawn` | 8 | 并发 spawn 数（仓颉线程） |
| `sinceTs` | 0 | 起始时间戳（增量处理） |
| `chooseKey` | None | key 过滤回调 |
| `keyToList` | None | 自定义 key 转列表逻辑 |
| `send` | None | KV 列表处理回调 |

## Backup/Restore

```cangjie
import std.io.*
import std.fs.*

// 备份数据库
let backupPath = "/tmp/backup.data"
let file = File(backupPath, OpenMode.Write)
let maxVersion = db.Backup(file)
println("Backup completed, max version: ${maxVersion}")
file.close()

// 恢复到新数据库
let db2 = Badger.open(Config(dir: "/tmp/restored_db"))
let restoreFile = File(backupPath, OpenMode.Read)
db2.Restore(restoreFile)
restoreFile.close()

// 增量备份（只备份指定版本后的数据）
let incrementalFile = File("/tmp/incremental.data", OpenMode.Write)
db.Backup(incrementalFile, since: lastBackupVersion)
```

## 配置选项

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `dir` | "" | 数据存储目录 |
| `memTableSize` | 64 MB | MemTable 大小 |
| `valueThreshold` | 1 MB | 超过此大小的 value 存入 VLog |
| `maxLevels` | 7 | LSM 层数 |
| `numLevelZeroTables` | 4 | L0 表数量阈值 |
| `disableWAL` | false | 禁用 WAL（性能测试用） |
| `detectConflicts` | true | 启用 SSI 冲突检测 |
| `inMemory` | false | 纯内存模式（不持久化） |
| `autoCloseOnExit` | false | 进程退出时自动关闭 |
| `syncWrites` | false | 每次写入后 fsync，确保严格持久性 |

## 内存使用

**每个库的常驻内存 ≈ arena（2 × memTableSize）+ 仓颉 GC 堆开销：**

| 项 | 默认值 | 说明 |
|------|--------|------|
| `memTableSize` | 64 MB | 单个 MemTable 上限 |
| arena | **2 × memTableSize（默认 128 MB/库）** | MemTable 内部分配器（skiplist 节点 + 数据），见 `memtable.cj: arenaSize = MemTableSize * 2` |
| 仓颉 GC 堆上限 | **256 MB（默认）** | 仓颉运行时默认堆上限，arena 等原生内存之外的 GC 托管对象均在此配额内 |

**仓颉 GC 堆调参（进程级环境变量）：**

```shell
export cjHeapSize=2GB            # 提高 GC 堆上限（默认 256MB）
export cjGCThreshold=1GB         # 触发 GC 的堆阈值（配套）
export cjGCInterval=100ms        # GC 轮询间隔（配套）
export cjBackupGCInterval=200ms  # 后台 GC 间隔（配套）
```

> 具体环境变量名以当前仓颉运行时版本为准（可用 `cjpm build` 后观察 GC 日志确认）。

**嵌入式 / 低内存 / 多库场景建议：**

- 调小 `memTableSize`：`Config().withMemTableSize(16 * 1024 * 1024u64)`（16MB，arena 32MB）或 `4 * 1024 * 1024u64`（4MB，arena 8MB）
- 同时打开多个库时，总内存 ≈ 每个库各一份 arena，请按库数量折算
- 降低 `cjHeapSize` 可以让 GC 更早回收，但会提高 GC 频率，需按写入负载权衡
- 纯缓存场景可用 `inMemory: true` 关闭磁盘持久化，但 arena 占用不变

## 事务 ACID 特性

### 原子性 (Atomicity)

- 所有事务条目使用 `bitTxn` 标记
- 事务结束写入 `bitFinTxn` 标记
- 崩溃恢复时，未完成事务自动丢弃

### 一致性 (Consistency)

- MVCC 多版本并发控制
- SSI 冲突检测

### 隔离性 (Isolation)

- Snapshot Isolation 快照隔离
- 事务内读取一致性视图

### 持久性 (Durability)

- WAL 先写机制
- `syncWrites=true` 时每次写入后 fsync
- 进程崩溃后数据可从 WAL 恢复

## 性能

**并发事务写入（50 并发）：**

| 规模 | 吞吐量 |
|------|--------|
| 50 x 100 = 5,000 keys | **459K keys/s** |
| 50 x 1,000 = 50,000 keys | **450K keys/s** |
| 50 x 3,000 = 150,000 keys | **396K keys/s** |

**单操作延迟：**

| 操作 | 延迟 |
|------|------|
| DB Get | ~2.9 µs |
| DB Set (事务内) | ~10.8 µs |
| Skiplist Put | ~2.0 µs |

详细基准测试报告请参阅 [benchmark-report.md](docs/benchmark-report.md)。

## 功能

### ✅ 已实现

| 功能 | 说明 |
|------|------|
| **KV 操作** | Get/Set/Delete（事务内） |
| **事务** | Begin/Commit/Rollback/Update/View |
| **SSI 隔离** | 可串行化快照隔离 + 冲突检测 |
| **迭代器** | 前向/反向/Seek/前缀过滤/validForPrefix |
| **PrefixIterable** | 支持 for-in 循环的前缀迭代器 |
| **快照** | 一致性快照读 |
| **MVCC** | 多版本并发控制 |
| **WAL** | Write-Ahead Log + 崩溃恢复 |
| **SSTable** | 前缀压缩 + Block 级别 CRC |
| **Value Log** | 大值分离存储 + GC |
| **MANIFEST** | 元数据管理 |
| **Compaction** | 完整多层级 L0→L1→...→L6 |
| **持久化** | DB.close() flush + DB.open() 恢复 |
| **并发安全** | 无锁并发 SkipList (真 CAS) |
| **批量写入** | batchSet / batchSetAsync |
| **TTL 过期** | withTTL() + 自动清理 |
| **用户元数据** | withMeta() 自定义标记 |
| **异常处理** | BadgerException + ErrorCode |
| **链式配置** | Config.withDir().withMemTableSize()... |
| **数据库信息** | isClosed/sync/size/tables/levels |
| **BloomFilter** | 读取优化，默认 1% 误判率 |
| **io_uring** | 异步 I/O，Linux 下默认开启，10-60% 性能提升 |
| **Stream API** | 大规模并发数据处理 |
| **Backup/Restore** | 全量/增量备份，支持 TTL 和 UserMeta |
| **InMemory 模式** | 纯内存模式，适合测试和临时缓存 |
| **Compression** | Snappy 压缩，减少存储空间 |

### ⏳ 待完善

| 功能 | 说明 |
|------|------|
| Encryption | 加密存储 |

## 参考

- [BadgerDB v4](https://github.com/dgraph-io/badger) - 原始 Go 实现
- [LSM-Tree](https://www.cs.umb.edu/~poneil/lsmtree.pdf) - Log-Structured Merge-Tree

## 文档

- [基准测试](docs/benchmark-report.md) - 性能测试报告
- [进度跟踪](docs/progress-tracking.md) - 项目进度和实现细节
- [设计文档](docs/plans/) - 各阶段设计文档

## 相关项目
- [bstrom-cj](https://atomgit.com/ystyle/badger-storm): orm操作层使用声明式查询构建器查询数据
- [sunku-cj](https://atomgit.com/ystyle/sunku-cj): redis指令格式的操作层
