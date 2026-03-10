# badger-cj

基于 LSM-Tree 的高性能 KV 存储引擎，移植自 Go [BadgerDB v4](https://github.com/dgraph-io/badger)。

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
    let opt = DBOptions(dir: "/tmp/mydb", valueDir: "/tmp/mydb")
    let db = DB.open(opt)
    
    // 2. 写入数据
    db.set("name".toByteArray(), "badger-cj".toByteArray())
    
    // 3. 读取数据
    if (let Some(vs) <- db.get("name".toByteArray())) {
        println("value: ${String(vs.value)}")
    }
    
    // 4. 关闭数据库
    db.close()
}
```

## 基本操作

### 打开/关闭数据库

```cangjie
let opt = DBOptions(
    dir: "/tmp/mydb",           // 数据目录
    valueDir: "/tmp/mydb",      // Value Log 目录（可与 dir 相同）
    memTableSize: 64 * 1024 * 1024u64,  // MemTable 大小
)
let db = DB.open(opt)

// 使用完毕后关闭
db.close()
```

### 读写数据

```cangjie
// Set
db.set("key".toByteArray(), "value".toByteArray())

// Get
if (let Some(vs) <- db.get("key".toByteArray())) {
    println("${vs.value}")  // Array<Byte>
}

// Delete
db.delete("key".toByteArray())
```

## 事务

### 推荐方式（自动管理）

```cangjie
// 读写事务 - 自动 commit/rollback
db.update({ txn =>
    txn.set("key".toByteArray(), "value".toByteArray())
    txn.delete("old-key".toByteArray())
})

// 只读事务
db.view({ txn =>
    if (let Some(val) <- txn.get("key".toByteArray())) {
        println("value: ${String(val)}")
    }
})
```

### 手动管理

```cangjie
let txn = db.newTransaction(update: true)
try {
    txn.set("key".toByteArray(), "value".toByteArray())
    txn.commit()
} finally {
    txn.discard()
}
```

## 迭代器

### 遍历所有 key

```cangjie
let txn = db.newTransaction(update: false)
let iter = txn.newIterator(IteratorOptions())
try {
    iter.rewind()
    while (iter.valid()) {
        let item = iter.item()
        println("key: ${String(item.key)}, value: ${String(item.value)}")
        iter.next()
    }
} finally {
    iter.close()
    txn.discard()
}
```

### 前缀扫描

```cangjie
let opt = IteratorOptions(prefix: "user:".toByteArray())
let iter = txn.newIterator(opt)
try {
    iter.rewind()
    while (iter.valid()) {
        let item = iter.item()
        println("${String(item.key)} = ${String(item.value)}")
        iter.next()
    }
} finally {
    iter.close()
}
```

### 反向遍历

```cangjie
let opt = IteratorOptions(reverse: true)
let iter = txn.newIterator(opt)
// ... 同上
```

## 配置选项

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `dir` | "" | 数据存储目录 |
| `valueDir` | "" | Value Log 目录 |
| `memTableSize` | 1 MB | MemTable 大小 |
| `tableSize` | 2 MB | SSTable 大小 |
| `valueThreshold` | 1 MB | 超过此大小的 value 存入 VLog |
| `maxLevels` | 7 | LSM 层数 |
| `disableWAL` | false | 禁用 WAL（性能测试用） |

## 性能

与 Go BadgerDB v4 性能对比（Arch Linux, AMD Ryzen 7 7840HS, 16 线程）：

**并发性能（主场景）：**

| 操作 | Go | Cangjie | 倍数 |
|------|-----|---------|------|
| Concurrent Write | ~250 ns/op | 457 ns/op | **1.8x** |
| Concurrent Read | ~96 ns/op | 116 ns/op | **1.2x** |

**单操作性能：**

| 操作 | Go | Cangjie | 倍数 |
|------|-----|---------|------|
| Skiplist Put | 976 ns | 2,469 ns | 2.5x |
| DB Set | 4,566 ns | 14,730 ns | 3.2x |
| DB Get | 708 ns | 3,901 ns | 5.5x |

## 功能对比

与 Go BadgerDB v4 的功能对比：

### ✅ 已实现

| 功能 | 说明 |
|------|------|
| **KV 操作** | Get/Set/Delete |
| **事务** | Begin/Commit/Rollback/Update/View |
| **SSI 隔离** | 可串行化快照隔离 + 冲突检测 |
| **迭代器** | 前向/反向/Seek/前缀过滤 |
| **快照** | 一致性快照读 |
| **MVCC** | 多版本并发控制 |
| **WAL** | Write-Ahead Log + 崩溃恢复 |
| **SSTable** | 前缀压缩 + Block 级别 CRC |
| **Value Log** | 大值分离存储 |
| **MANIFEST** | 元数据管理 |
| **Compaction** | L0→L1 压缩（简化版） |
| **持久化** | DB.close() flush + DB.open() 恢复 |
| **并发安全** | 无锁并发 SkipList (真 CAS) |

### ⏳ 未实现

| 功能 | 优先级 | 说明 |
|------|--------|------|
| Managed DB | P2 | 手动管理时间戳 |
| Stream API | P2 | 大规模数据处理 |
| Transaction View | P2 | 回调式只读事务 |
| Iterator 预取 | P2 | prefetchSize/prefetchValues |
| Value Log GC | P3 | 垃圾回收优化 |
| Backup/Restore | P4 | 数据备份恢复 |
| Merge Operator | P4 | 原子更新操作 |
| Encryption | P4 | 加密存储 |

## 参考

- [BadgerDB v4](https://github.com/dgraph-io/badger) - 原始 Go 实现
- [LSM-Tree](https://www.cs.umb.edu/~poneil/lsmtree.pdf) - Log-Structured Merge-Tree

## 文档

- [进度跟踪](docs/progress-tracking.md) - 项目进度和实现细节
- [设计文档](docs/plans/) - 各阶段设计文档
