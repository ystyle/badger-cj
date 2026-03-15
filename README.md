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
  badgercj = { path = "path/to/badger-cj" }
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
    let iter = txn.newIterator(IteratorOptions())
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
// 方式 1：使用 IteratorOptions.prefix
db.view({ txn =>
    let opt = IteratorOptions(prefix: "user:".toArray())
    let iter = txn.newIterator(opt)
    iter.rewind()
    while (iter.valid()) {
        let item = iter.item()
        println("${String.fromUtf8(item.key())} = ${String.fromUtf8(item.value())}")
        iter.next()
    }
})

// 方式 2：使用 validForPrefix（更灵活）
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
    let iter = txn.newIterator(opt)
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
let iter = snapshot.newIterator(IteratorOptions())
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

### ⏳ 未实现

| 功能 | 优先级 | 说明 |
|------|--------|------|
| WriteBatch | P1 | 批量写入优化 |
| Compression | P2 | SSTable 压缩（需要 Snappy/Zstd 库） |
| BloomFilter | P2 | 读取优化，减少磁盘访问 |
| Managed DB | P2 | 手动管理时间戳 |
| Stream API | P2 | 大规模数据处理 |
| Iterator 预取 | P2 | prefetchSize/prefetchValues |
| Backup/Restore | P4 | 数据备份恢复 |
| Merge Operator | P4 | 原子更新操作 |
| Encryption | P4 | 加密存储 |

## 参考

- [BadgerDB v4](https://github.com/dgraph-io/badger) - 原始 Go 实现
- [LSM-Tree](https://www.cs.umb.edu/~poneil/lsmtree.pdf) - Log-Structured Merge-Tree

## 文档

- [基准测试](docs/benchmark-report.md) - 性能测试报告
- [进度跟踪](docs/progress-tracking.md) - 项目进度和实现细节
- [设计文档](docs/plans/) - 各阶段设计文档