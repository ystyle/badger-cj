# badger-cj

基于 LSM-Tree 的高性能 KV 存储引擎，移植自 Go [BadgerDB v4](https://github.com/dgraph-io/badger)。

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

与 Go BadgerDB v4 性能对比（Arch Linux, AMD Ryzen 7 7840HS）：

| 操作 | Go | Cangjie | 倍数 |
|------|-----|---------|------|
| Skiplist Put | 976ns | 2,469ns | 2.5x |
| DB Set | 4,566ns | 14,730ns | 3.2x |
| DB Get | 708ns | 3,901ns | 5.5x |

## 参考

- [BadgerDB v4](https://github.com/dgraph-io/badger) - 原始 Go 实现
- [LSM-Tree](https://www.cs.umb.edu/~poneil/lsmtree.pdf) - Log-Structured Merge-Tree
