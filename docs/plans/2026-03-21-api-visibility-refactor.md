# API 可见性重构计划

## 状态：✅ 已完成

## 实际修改总结

### 修改策略调整

由于仓颉语言的访问修饰符规则：
- 接口方法默认是 `public`，实现类不能降低可见性
- `public init` 不能使用 `protected` 类型的参数

**实际采用方案：**
1. 用户 API 保持 `public`
2. 内部类声明为 `protected class`，方法改为 `protected`
3. Badger 构造函数改为 `protected`（用户通过 `open()` 打开数据库）
4. VLogGCDB 接口方法保持默认（`public`），Badger 实现也保持 `public`

### 已修改文件

| 文件 | 修改内容 |
|------|---------|
| `db/badger.cj` | `init` 改为 `protected`，内部方法改为 `protected`，接口实现保持 `public` |
| `db/transaction.cj` | 内部方法改为 `protected` |
| `db/helpers.cj` | 全部函数改为 `protected` |
| `db/file_io.cj` | 全部函数改为 `protected` |
| `db/memtable.cj` | `class` 改为 `protected`，方法改为 `protected` |
| `db/oracle.cj` | `class` 改为 `protected`，方法改为 `protected` |
| `db/watermark.cj` | `class` 改为 `protected`，方法改为 `protected` |
| `db/compaction.cj` | `class` 改为 `protected`，方法改为 `protected` |
| `db/levels.cj` | `class` 改为 `protected`，方法改为 `protected` |
| `db/level_handler.cj` | `class` 改为 `protected`，方法改为 `protected` |
| `db/backup.cj` | `class` 改为 `protected`，方法改为 `protected` |
| `db/notifying_channel.cj` | `class` 改为 `protected`，方法改为 `protected` |
| `db/stream.cj` | `KeyRange` 改为 `protected class` |
| `db/memtable_iterator.cj` | `init` 改为 `protected` |
| `db/table_adapter.cj` | `init` 和 `getTable` 改为 `protected` |
| `db/table_iterator_wrapper.cj` | `init` 改为 `protected` |
| `db/wal.cj` | `replay` 改为 `protected` |
| `arena/arena.cj` | `class` 改为 `protected`，方法改为 `protected` |
| `skiplist/*.cj` | `class` 改为 `protected`，方法改为 `protected` |
| `table/*.cj` | `class` 改为 `protected`，方法改为 `protected` |
| `vlog/*.cj` | `class` 改为 `protected`，方法改为 `protected` |
| `manifest/*.cj` | `class` 改为 `protected`，方法改为 `protected` |
| `encoding/*.cj` | `class` 改为 `protected`，函数改为 `protected` |
| `utils/*.cj` | 函数改为 `protected` |

### 测试结果

- **270/270 测试通过** ✅

---

## 背景

根据仓颉语言文档《顶层声明的可见性》：
- `public` - 模块内外均可见
- `protected` - 仅当前模块内可见
- `internal` - 仅当前包及子包内可见
- `private` - 仅当前文件内可见

项目 `badgercj` 是一个 cjpm 模块，所有包都在同一模块内，使用 `protected` 可以让模块内部互相访问，外部不可见。

## 目标

1. 用户 API 保持 `public` - 供外部调用者使用
2. 内部实现改为 `protected` - 模块内部使用，不暴露给外部
3. 包内工具函数改为 `internal` - 仅当前包内使用

---

## 一、保持 public 的 API（用户接口）

### 1.1 db 包 - 核心用户 API

| 类 | 方法 | 说明 |
|---|---|---|
| **Badger** | `open(opt: Config): Badger` | 打开数据库 |
| | `close()` | 关闭数据库 |
| | `get(key, readTsOpt?): Option<ValueStruct>` | 读取数据 |
| | `batchSet(entries)` | 批量写入 |
| | `batchSetAsync(entries, callback?)` | 异步批量写入 |
| | `newTransaction(update?): Transaction` | 创建事务 |
| | `view(fn)` | 只读事务 |
| | `update(fn)` | 读写事务 |
| | `newSnapshot(): Snapshot` | 创建快照 |
| | `isClosed(): Bool` | 是否已关闭 |
| | `sync()` | 同步到磁盘 |
| | `size(): DBSize` | 获取大小 |
| | `tables(): ArrayList<SSTableInfo>` | 获取表信息 |
| | `levels(): ArrayList<LevelInfo>` | 获取层级信息 |
| | `compact()` | 手动压缩 |
| | `runVLogGC(discardRatio): Bool` | 手动 GC |
| | `flushMemTable()` | 刷新 MemTable |
| | `Backup(writer, since?): UInt64` | 备份 |
| | `Restore(reader)` | 恢复 |
| **Transaction** | `get(key): Option<Array<Byte>>` | 读取 |
| | `set(key, value)` | 写入 |
| | `setEntry(e: Entry)` | 写入 Entry |
| | `delete(key)` | 删除 |
| | `commit()` | 提交 |
| | `rollback()` | 回滚 |
| | `discard()` | 丢弃 |
| | `newIterator(opt?): Iterator` | 创建迭代器 |
| **Iterator** | `rewind()` | 重置到开头 |
| | `valid(): Bool` | 是否有效 |
| | `validForPrefix(prefix): Bool` | 前缀检查 |
| | `next()` | 下一个 |
| | `item(): Item` | 获取当前项 |
| | `seek(key)` | 定位 |
| | `close()` | 关闭 |
| **Snapshot** | `get(key): ?Item` | 读取 |
| | `newIterator(opt?): Iterator` | 创建迭代器 |
| | `getReadTs(): UInt64` | 获取时间戳 |
| | `discard()` | 释放 |
| **Item** | `keyCopy(): Array<Byte>` | 获取 key |
| | `valueCopy(): Array<Byte>` | 获取 value |
| | `keySize(): Int64` | key 大小 |
| | `valueSize(): Int64` | value 大小 |
| | `isDelete(): Bool` | 是否删除 |
| | `isValuePointer(): Bool` | 是否指针 |
| | `discardEarlierVersions(): Bool` | 是否丢弃旧版本 |
| | `isDeletedOrExpired(): Bool` | 是否已删除/过期 |
| | `userMeta: Byte` | 用户元数据 |
| | `version: UInt64` | 版本号 |
| | `expiresAt: UInt64` | 过期时间 |
| **Entry** | `new(key, value): Entry` | 创建 Entry |
| | `delete(key): Entry` | 创建删除 Entry |
| | `withMeta(userMeta): Entry` | 设置用户元数据 |
| | `withTTL(dur: Duration): Entry` | 设置 TTL |
| | `withDiscard(): Entry` | 设置丢弃旧版本 |
| | `withExpiresAt(exp): Entry` | 设置过期时间 |
| **Config** | `withDir(dir): Config` | 设置目录 |
| | `withMemTableSize(size): Config` | 设置 MemTable 大小 |
| | `withValueThreshold(t): Config` | 设置 VLog 阈值 |
| | `withMaxLevels(n): Config` | 设置层数 |
| | `withNumLevelZeroTables(n): Config` | 设置 L0 表数 |
| | `withDisableWAL(bool): Config` | 禁用 WAL |
| | `withDetectConflicts(bool): Config` | 冲突检测 |
| | `withBloomFalsePositive(fp): Config` | Bloom 误判率 |
| | `withUseIoUring(bool): Config` | io_uring |
| **Stream** | `orchestrate()` | 执行流式处理 |
| | `prefix: Array<Byte>` | 前缀过滤 |
| | `numSpawn: Int64` | 并发数 |
| | `sinceTs: UInt64` | 起始时间戳 |
| | `send: ?(ArrayList<StreamKV>) -> Unit` | 处理回调 |
| **StreamKV** | 全部字段 | key, value, userMeta, version, expiresAt, meta |
| **DBSize** | 全部字段 | lsm, vlog |
| **SSTableInfo** | 全部字段 | ID, Level, KeyCount 等 |
| **LevelInfo** | 全部字段 | Level, NumTables, Size 等 |
| **BadgerException** | 全部 | 异常类 |

### 1.2 table 包 - 部分公开

| 类 | 方法 | 说明 |
|---|---|---|
| **ValueStruct** | `value, meta, userMeta, version, expiresAt` | 字段公开 |
| | `encode(): Array<Byte>` | 编码 |
| | `decode(encoded): ValueStruct` | 解码 |
| **ValuePointer** | `fid, len, offset` | 字段公开 |
| | `encode(): Array<Byte>` | 编码 |
| | `decode(data): ValuePointer` | 解码 |
| **Meta** | `bitDelete, bitValuePointer, ...` | 静态常量公开 |

### 1.3 vlog 包 - 部分公开

| 类 | 方法 | 说明 |
|---|---|---|
| **LogEntry** | `key, value, meta, expiresAt, version` | 字段公开 |
| | `encode(): Array<Byte>` | 编码 |
| | `decode(data, offset): (LogEntry, Int64)` | 解码 |

---

## 二、改为 protected 的 API（模块内部）

### 2.1 db 包 - 内部实现

| 类 | 方法 |
|---|---|
| **Badger** | getMemTable, getImmMemTables, getMemTables, getLevelsController, getManifestFile, getLevelHandler, getOpt, getCompactStatus, getVS, setRaw, getValueThreshold, ranges, updateNextTs, doneRestore, getVersion, flushWAL, getOracle |
| **Transaction** | getWrites, isCommitted, isDiscarded, getDB, isUpdate |
| **MemTable** | 全部方法 |
| **Oracle** | 全部方法 |
| **WaterMark** | 全部方法 |
| **Compaction** | 全部方法 |
| **BackupWriter** | addKV, flush, finish |
| **BackupReader** | restore |
| **NotifyingWriteChannel** | 全部方法 |
| **KeyRange** | 全部 |

### 2.2 db 包 - helpers.cj（改为 internal）

全部函数：
- `keyWithTs`, `parseTs`, `parseKey`, `parseKeyIfHasTs`
- `sameKey`, `safeCopy`, `isBadgerKey`
- `manifestPath`, `walPath`, `sstablePath`
- `isDeletedOrExpired`, `discardEntry`

### 2.3 db 包 - file_io.cj（改为 internal）

全部函数：
- `writeFile`, `syncWriteFile`

### 2.4 arena 包

| 类 | 方法 |
|---|---|
| **Arena** | 全部方法 |

### 2.5 skiplist 包

| 类 | 方法 |
|---|---|
| **Skiplist** | 全部方法 |
| **Node** | 全部方法 |
| **AtomicStorage** | 全部方法 |
| **SkipIterator** | 全部方法 |
| **ffi_utils.cj** | 全部函数 |

### 2.6 table 包

| 类 | 方法 |
|---|---|
| **Table** | 全部方法 |
| **TableBuilder** | 全部方法 |
| **BlockBuilder** | 全部方法 |
| **TableIterator** | 全部方法 |
| **BlockIterator** | 全部方法 |
| **TableIndex** | 全部方法 |
| **BloomFilter** | 全部方法 |

### 2.7 vlog 包

| 类 | 方法 |
|---|---|
| **VLog** | 全部方法 |
| **VLogManager** | 全部方法 |
| **VLogFile** | 全部方法 |
| **DiscardStats** | 全部方法 |
| **GCFileRewriter** | 全部方法 |
| **VLogGCDB** | 接口方法 |

### 2.8 manifest 包

| 类 | 方法 |
|---|---|
| **ManifestFile** | 全部方法 |
| **Manifest** | 全部方法 |
| **ManifestChange** | 全部方法 |

### 2.9 encoding 包

| 类 | 方法 |
|---|---|
| **CRC32C** | 全部方法 |
| **Varint** | 全部方法 |
| `checksumCRC32C` | 函数 |
| `encodeVarint`, `decodeVarint` | 函数 |

### 2.10 utils 包

全部函数改为 internal：
- `compareKeys`, `keysEqual`, `hasPrefix`, `hashKey`
- `u32ToLE`, `u32FromLE`, `u64ToLE`, `u64FromLE`

---

## 三、修改清单（按文件）

### 3.1 db 包

| 文件 | 修改 |
|------|------|
| `badger.cj` | 15 个方法保持 public，其余改 protected |
| `transaction.cj` | 9 个方法保持 public，其余改 protected |
| `iterator.cj` | 全部 public（用户 API） |
| `snapshot.cj` | 全部 public（用户 API） |
| `item.cj` | 全部 public（用户 API） |
| `entry.cj` | 全部 public（用户 API） |
| `config.cj` | 全部 public（用户 API） |
| `stream.cj` | orchestrate public，内部方法 protected |
| `backup.cj` | 全部 protected |
| `memtable.cj` | 全部 protected |
| `oracle.cj` | 全部 protected |
| `watermark.cj` | 全部 protected |
| `compaction.cj` | 全部 protected |
| `levels.cj` | 全部 protected |
| `level_handler.cj` | 全部 protected |
| `helpers.cj` | 全部 internal |
| `file_io.cj` | 全部 internal |
| `notifying_channel.cj` | 全部 protected |

### 3.2 其他包

| 包 | 修改 |
|------|------|
| `arena/` | 全部 protected |
| `skiplist/` | 全部 protected |
| `table/` | ValueStruct/ValuePointer/Meta 部分公开，其余 protected |
| `vlog/` | LogEntry 部分公开，其余 protected |
| `manifest/` | 全部 protected |
| `encoding/` | 全部 protected |
| `utils/` | 全部 internal |

---

## 四、对照 README 示例验证

### 4.1 基本操作（应全部可用）

```cangjie
// ✅ public
let db = Badger.open(Config(dir: "/tmp/mydb"))
db.update { txn => txn.set("key".toArray(), "value".toArray()) }
db.view { txn => txn.get("key".toArray()) }
db.close()
```

### 4.2 事务操作（应全部可用）

```cangjie
// ✅ public
db.update { txn =>
    txn.set("key".toArray(), "value".toArray())
    txn.delete("old".toArray())
    txn.get("key".toArray())
}
db.view { txn => txn.get("key".toArray()) }
```

### 4.3 迭代器（应全部可用）

```cangjie
// ✅ public
db.view { txn =>
    let iter = txn.newIterator()
    iter.rewind()
    while (iter.valid()) {
        let item = iter.item()
        println(item.keyCopy())
        iter.next()
    }
}
```

### 4.4 TTL 和元数据（应全部可用）

```cangjie
// ✅ public
let entry = Entry.new("key".toArray(), "value".toArray())
    .withTTL(Duration.hour * 24)
    .withMeta(0x42)
db.batchSet(ArrayList<Entry>([entry]))
```

### 4.5 快照（应全部可用）

```cangjie
// ✅ public
let snapshot = db.newSnapshot()
if (let Some(item) <- snapshot.get("key".toArray())) {
    println(item.valueCopy())
}
snapshot.discard()
```

### 4.6 Stream API（应全部可用）

```cangjie
// ✅ public
let stream = Stream(db)
stream.prefix = "user:".toArray()
stream.numSpawn = 16
stream.send = { kvs => /* 处理 */ }
stream.orchestrate()
```

### 4.7 Backup/Restore（应全部可用）

```cangjie
// ✅ public
let file = File(backupPath, OpenMode.Write)
db.Backup(file)
file.close()

let restoreFile = File(backupPath, OpenMode.Read)
db.Restore(restoreFile)
```

### 4.8 数据库信息（应全部可用）

```cangjie
// ✅ public
db.isClosed()
db.sync()
let size = db.size()
let tables = db.tables()
let levels = db.levels()
```

### 4.9 配置（应全部可用）

```cangjie
// ✅ public
let opt = Config()
    .withDir("/tmp/mydb")
    .withMemTableSize(128 * 1024 * 1024u64)
    .withDisableWAL(false)
```

### 4.10 不应暴露的内部 API（改为 protected 后外部不可用）

```cangjie
// ❌ protected - 外部不可访问
db.getMemTable()
db.getOracle()
db.getLevelsController()
db.setRaw(...)

// ❌ internal - 外部不可访问
keyWithTs(key, ts)
parseTs(key)
writeFile(path, data)
```

---

## 五、执行步骤

1. 修改 db 包核心文件（badger.cj, transaction.cj 等）
2. 修改 db 包工具文件（helpers.cj, file_io.cj）
3. 修改 arena/skiplist/table/vlog/manifest/encoding 包
4. 修改 utils 包
5. 运行全量测试验证
6. 更新 README（如有需要）

---

## 六、注意事项

1. **接口方法**：interface 的方法不加修饰符，实现类需要匹配
2. **struct 字段**：StreamKV/DBSize 等结构体字段需要保持 public
3. **静态方法**：Entry.new(), Entry.delete() 等工厂方法保持 public
4. **泛型类型**：修改后确保类型参数不变
5. **测试文件**：测试文件可以访问 protected（同模块），无需修改