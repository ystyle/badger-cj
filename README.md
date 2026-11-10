# badger-cj

一个可嵌入、持久化且速度很快的基于LSM-Tree的键值 (KV) 数据库，移植自 Go [BadgerDB v4](https://github.com/dgraph-io/badger)。

> ⚠️ **兼容性声明（2.0）**
>
> - ✅ **API 语义对齐** —— 接口设计遵循 Go BadgerDB v4（P0/P1 全部对齐，2.0 补齐 WriteBatch / MergeOperator / Managed DB / Sequence / EstimateSize）
> - ✅ **自有磁盘格式** —— 2.0 起字节布局由本项目自行维护（SSTable/MANIFEST/LogEntry 与 v1.6.x 一致，WAL/VLog 的**文件布局**与物理大小不同：WAL 多段、VLog 稀疏预分配）；数据目录写出 `FORMAT` 基线（`format=1`），未知 feature/更高格式会被拒绝打开
> - ✅ **可升级** —— 2.0 可直接打开 v1.6.x 数据目录（首次打开补写 `FORMAT`），**不支持降级回 v1.6.x**
> - ❌ **不承诺与 Go BadgerDB 数据文件互相兼容** —— 不做跨语言数据迁移，也不追求与 Go 字节级格式一致

## 安装

在 `cjpm.toml` 中添加依赖：

```toml
[dependencies]
  "badgercj" = "2.2.0" # 注意使用最新的版本
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
- **Docker/容器环境建议同时开启优雅退出**：`atExit` / `AutoCloseOnExit` 只在**正常退出路径**触发（main 返回 / `std.env.exit()`），**不处理 docker 的 SIGTERM**——`docker stop` / `docker compose restart` 发的信号直接终止进程，退出回调不会执行（已实测确认）。容器内建议调用 `registerSignalShutdown()`，注册 SIGINT/SIGTERM → 收到信号后先 `close()` 再退出进程，保证退出路径上 memtable 落盘：

```cangjie
let db = Badger.open(Config(dir: "./data"))
db.registerSignalShutdown()   // docker stop / Ctrl+C → 优雅关闭后退出（exitAfterClose: false 可只关闭不退出）
```

> 条件编译：信号 API（std.runtime）官方不支持 Windows，`registerSignalShutdown()` 仅 Linux 编译（非 Linux 为 no-op；macOS 如需支持可放宽）。
> 兜底建议：低频写场景仍可叠加 `Config.withSyncWrites(true)` 同步落盘，即使 SIGKILL 也不丢数据。

**与宿主进程共存监听信号（两种模式，按需选择）：**

std.runtime 同一信号可注册多个 handler（FIFO 执行；返回 `true` 停止后续 handler——badger 必须返回 `true` 以阻止信号默认终止行为，实测返回 `false` 会让 SIGTERM 直接杀掉进程、close 来不及执行）：

- **模式 A：宿主先注册自己的 handler，再调 `registerSignalShutdown()`**——宿主 handler 只做置位并**返回 `false`**（继续分发），badger 的 handler 随后执行并阻止默认行为；宿主真清理放自己的后台线程：

```cangjie
registerSignalHandler(Signal.SIGTERM, { _ => myStopFlag.store(true); false })
db.registerSignalShutdown()   // 必须后注册（badger handler 返回 true 放链尾）
```

- **模式 B（推荐）：宿主把清理逻辑注册进 badger**——`registerShutdownHook()`，信号触发时在后台线程、`close()` 之前按注册顺序执行，无注册顺序依赖、信号上下文安全：

```cangjie
db.registerShutdownHook({ => myServer.stop() })   // 关服务 / 停写入等收尾逻辑
db.registerShutdownHook({ => myFlag.store(true) })
db.registerSignalShutdown()   // SIGTERM → 依次执行钩子 → close() 落盘 → exit
```

> 注意：钩子仅在 `registerSignalShutdown()` 的信号关闭路径执行（不随普通 `close()` 触发）；钩子执行时数据库尚未 close，可安全读写。

**端到端验证（scripts/graceful_shutdown_e2e.sh）**：写入 5000 条（不 close、不 flush，数据仅内存）→ `kill -TERM` 模拟 `docker stop` → 进程 exit(0) 且数据落盘（SSTable+MANIFEST）→ 重启读回 5000/5000（多轮稳定通过）。对照组（不注册优雅退出）SIGTERM 默认终止（143）→ 重启 0/5000 全丢，凸显本 API 价值。示例程序 `src/examples/graceful_exit`（编译参数已加 `--static`，二进制无仓颉 runtime 动态依赖）。

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

// 运行统计快照（2.2）：读/flush/compaction 计数、memtable 用量、各层表数与字节数、块缓存
let st = db.getStats()
println("gets=${st.Gets} flushes=${st.Flushes} compactions=${st.Compactions}")
println("memtable=${st.MemTableBytes}B imm=${st.ImmCount} tables=${st.TableCount} bytes=${st.TableBytes}")
// arena：已用 / 分配（之比即利用率；MaxBatchBytes = 历史最大单批预留，用于判断预留是否过肥）
println("arena used=${st.MemTableUsedBytes}B allocated=${st.MemTableArenaBytes}B maxBatch=${st.MaxBatchBytes}B")
println("blockCache hits=${st.BlockCache.Hits} misses=${st.BlockCache.Misses} used=${st.BlockCache.UsedBytes}B")
for (ls in st.Levels) {
    println("Level ${ls.Level}: ${ls.TableCount} tables, ${ls.Bytes} bytes")
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

**性能提示（实测，务必优先用批量）**：同一 40 万 key / 8 线程负载下
（`src/examples/txn_queue_perf`，可用 `keysPerTxn` 参数复现）：

| 事务粒度 | 事务数 | 每 key 成本 | 相对单键 |
|---|---|---|---|
| 单键事务 | 400000 | 6778–6857 ns | 1x |
| **8 key/事务** | 50000 | **2216–2494 ns** | **快 2.7–3.1x** |
| 64 key/事务 | 6248 | 1715–1969 ns | 快 3.5–4.0x |

批量摊薄的不只是那一次同步往返（约 1.1 µs），还包括每事务的固定开销：
事务对象、时间戳分配、WAL 写入、请求池取还。**写吞吐敏感的场景，事务粒度建议 ≥8 key 起步。**

> 注意：`batchSetAsync` 每批会 `spawn` 一个等待线程，**高频小批量调用会导致线程膨胀**
> （线程数 = 批次数）；它适合"批量大、频率低"的场景，此时能把等待移出调用方线程。

## 2.0 新增 API

### WriteBatch（用户侧批量写）

```cangjie
let wb = db.newWriteBatch()
for (i in 0..1000) {
    wb.set("k${i}".toArray(), "v${i}".toArray())
}
wb.flush() // 达到单事务上限（15% MemTableSize / 条数上限）会自动切分并提交
```

失败后批进入错误态（`getError()`），后续操作抛异常；`cancel()` 丢弃未提交条目。

### MergeOperator（读-改-写合并）

```cangjie
import std.convert.*
import std.time.*

// 计数器：existing 是已折叠值，incoming 是本次追加值
let op = db.getMergeOperator("counter".toArray(), { existing, incoming =>
    (Int64.parse(String.fromUtf8(existing)) + Int64.parse(String.fromUtf8(incoming))).toString().toArray()
}, interval: Duration.millisecond * 100)
op.add("1".toArray())
op.add("2".toArray())
println(String.fromUtf8(op.get())) // "3"
op.stop() // 必须停掉后台折叠线程（db.close 也会统一停）
```

后台线程按 `interval` 折叠并回写带 discard 位的普通条目；compaction 之后旧 merge 链被回收。

### Managed DB（外部指定时间戳）

```cangjie
let db = Badger.openManaged(Config(dir: "/tmp/mydb", numVersionsToKeep: 3))
let txn = db.newTransactionAt(100, update: true)
txn.set("k".toArray(), "v".toArray())
txn.commitAt(100)
db.setDiscardTs(90) // 允许 compaction 丢弃 <= 90 的旧版本
```

managed 库不能开普通读事务（内部取自动时间戳会报错），必须用 `newTransactionAt(ts)`；
`numVersionsToKeep` 必须按外部最老 readTs 的需求调大，否则旧快照会丢数据。

### Sequence（租约式单调递增）

```cangjie
let seq = db.getSequence("order-id".toArray(), 100) // 租约带宽 100
let id = seq.nextValue()
seq.release() // 退回未用完的区间（下次从退回处继续）
```

### 前缀容量估算

```cangjie
let (onDisk, uncompressed) = db.estimateSize("user/".toArray())
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

## 键的限制

- **user key 不应互为前缀**（如同时使用 key-1 与 key-10、user 与 user:name）。
  存储键是「user key + 8 字节倒序时间戳」，并按原始字节比较；user key 互为前缀时，
  追加的时间戳字节会与更长 key 的下一个字符混排，导致 seek 定位歧义、部分 get 落空
  （数据仍在，allVersions 迭代器可见）。这是 Go badger 同款编码的固有限制，不是本移植
  引入；实测等宽零填充 key 无此问题（详见 docs/issue/2026-11-09-read-miss-after-compaction.md）。
  需要层级命名时，可用固定长度前缀或分隔符保证「不存在前缀关系」（如 user:0001）。

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
| `syncWrites` | false | 写入批次结束后 sync（msync），确保严格持久性 |
| `mmapWAL` | true | WAL 走 mmap（段内固定映射 + 稀疏预分配，段满换段） |
| `mmapVLog` | true | VLog 走 mmap（稀疏预分配 `vlogFileSize`，段内固定映射） |
| `mmapSSTable` | true | SSTable 只读映射（数据在页缓存，不占 GC 堆；读块是复制语义） |
| `vlogFileSize` | 1 GB | VLog 单段容量（GC 只能回收非当前段） |
| `numVersionsToKeep` | 1 | compaction 每个 key 至少保留的版本数（managed DB 必须调大） |
| `numMemtables` | 5 | 允许的未落盘 memtable 上限（写路径背压阈值） |
| `useIoUring` | true | Linux 下用 io_uring 写 SSTable（不可用/失败自动降级同步写） |
| `compression` | None | SSTable 块压缩（Snappy）；默认关闭，mmap 读是零拷贝路径 |
| `blockCacheSizeMB` | 0（关闭） | 2.1 块缓存：LRU 缓存热 block（128MB 数据 113 → 37 µs/Get）；生产建议 64–256 |
| `arenaGrowthStartBytes` | 256 KB | 2.2 arena 渐进扩容起点（首张 memtable 用该值，每轮换翻倍、封顶目标值）；0 = 关闭渐进。单条大于当前 arena 时按需抬升 |
| `streamingSSTable` | false | 2.2 流式落盘：flush/compaction 边构建边写文件，不再留整表副本；低堆/大表场景建议开 |

## 内存使用

**每个库的常驻内存 ≈ arena（约 1.3 × memTableSize）+ 仓颉 GC 堆开销：**

| 项 | 默认值 | 说明 |
|------|--------|------|
| `memTableSize` | 64 MB | 单个 MemTable 上限 |
| arena 目标值 | **memTableSize + 15% 批次预留（约 1.3 × memTableSize；默认 64MB 表约 84MB/库）** | 对齐 badger-go 的 arenaSize()；每张 memtable 用满即轮换 |
| `arenaGrowthStartBytes` | 256 KB | 2.2 起 arena **渐进扩容**：首张 memtable 用该值，每轮换翻倍、封顶目标值；**0 = 关闭渐进**。单条条目比当前 arena 大时按需抬升（大 value 内联不受起点限制） |
| `blockCacheSizeMB` | 0（关闭） | 2.1 块缓存：LRU 缓存热 block，把 mmap 随机读拉回堆内水平（128MB 数据 113 → 37 µs/Get）；生产建议 64–256 |
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

- 调小 `memTableSize`：`Config().withMemTableSize(16 * 1024 * 1024u64)`（16MB，arena 目标约 21MB；首张表从 256KB 渐进）或 `4 * 1024 * 1024u64`（4MB，arena 目标约 5.3MB）

**低堆 / 大表场景：流式落盘（2.2，建议开启）**

Config(streamingSSTable: true) 让 flush/compaction 边构建边写文件（io_uring 分段提交，失败回退同步写），不再在内存里多留一份整表副本。低堆下这是决定性的（实测 128MB 堆、写 24MB）：

| memTableSize | NumMemtables | 整表字节（默认） | 流式落盘 |
|---|---|---|---|
| 4MB | 2 | OOM | 通过（632ms） |
| 4MB | 5 | OOM | OOM |
| 16MB | 2 | OOM | OOM |
| 16MB | 5 | OOM | OOM |

注意：流式落盘解决的是「单次 flush 的整表副本」，memtable 集合本身超堆仍需调小 memTableSize / NumMemtables（上表后三行即为此）。
- 同时打开多个库时，总内存 ≈ 每个库各一份 arena，请按库数量折算
- 降低 `cjHeapSize` 可以让 GC 更早回收，但会提高 GC 频率，需按写入负载权衡
- 纯缓存场景可用 `inMemory: true` 关闭磁盘持久化，但 arena 占用不变
- 2.0 起 SSTable/VLog/WAL 走 mmap（`mmapSSTable/mmapVLog/mmapWAL` 默认开）：表数据与段数据在页缓存，不占 GC 堆；关闭 mmap 会回退到堆内数组/无缓冲 File 写

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

> 2026-10-10 于 v1.6.21 重测（16 核，`cjHeapSize=12gb`，数据目录落在真实盘，
> 每项 5 轮取中位数）。方法学见 [benchmark-methodology.md](docs/benchmark-methodology.md)，
> 完整数据与读数注意事项见 [benchmark-report.md](docs/benchmark-report.md)。

**并发事务写入（50 并发事务，v1.6.21 实测中位数）：**

| 规模 | 吞吐量 | 离散度 |
|------|--------|--------|
| 50 x 100 = 5,000 keys | **634K keys/s** | ±13.4% |
| 50 x 1,000 = 50,000 keys | **730K keys/s** | ±5.1% |
| 50 x 3,000 = 150,000 keys | **567K keys/s** | ±2.1% |

**并发跳表（5000 ops / 16 线程）：** 并发写约 **390 ns/op**、并发读约 **330 ns/op**，
并发吞吐约 **260 万次/秒**。⚠️ 该基准负载仅约 64ms，30 轮实测离散度 ±40%，
故只宜作"亚微秒级"的定性表述，不可引用点值。

**单操作延迟（中位数，注意各自的口径）：**

| 基准 | 操作 | 延迟 | 离散度 |
|------|------|------|--------|
| `examples.perf` | DB Set（20 事务 × 200 key/事务，批内摊薄） | 1.43 µs | ±11.0% |
| `examples.perf` | DB Get（单事务内 4000 次读） | 2.68 µs | ±2.5% |
| `cjpm bench` | benchDBSet（单次 set） | 15.67 µs | ±9.1% |
| `cjpm bench` | benchDBGet（单次 get） | 5.54 µs | ⚠️ ±68.5% |
| `cjpm bench` | benchPut（跳表单次 put） | 1.04 µs | ⚠️ ±45.5% |

> `examples.perf` 与 `cjpm bench` 的口径不同（前者批内摊薄、后者单次调用），
> 因此数值不可互相比较 —— 引用时必须带上是哪个基准。

**与 Go BadgerDB v4.9.1 的对照**（同机同 N=5000）：纯并发写 Go 约 150 ns/op、
badger-cj 约 390 ns/op（±40%），**约慢 2.6 倍**。
此比值强依赖所选的测量规模，详见基准报告 §3。

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
| **io_uring** | 异步 I/O，Linux 下默认开启；**收益取决于 workload** —— 大写入量/高并发可快 1.1-1.6x，小文件（4MB）批量写反而慢 2-6x，详见[基准报告](docs/benchmark-report.md) §6/§7 |
| **Stream API** | 大规模并发数据处理 |
| **Backup/Restore** | 全量/增量备份，支持 TTL 和 UserMeta |
| **InMemory 模式** | 纯内存模式，适合测试和临时缓存 |
| **Compression** | Snappy 压缩，减少存储空间 |
| **mmap WAL/VLog/SSTable**（2.0） | WAL 多段 + 稀疏预分配、VLog 段内固定映射、SSTable 只读映射；数据不再整体驻留 GC 堆 |
| **分组提交**（2.0） | 同批写请求共享一次 WAL 映射写 + 一次 msync；`syncWrites` 下按批持久化 |
| **WriteBatch**（2.0） | 用户侧批量写，按单事务上限自动切分；`flush/cancel/getError` |
| **MergeOperator**（2.0） | 读-改-写合并算子（计数器/列表追加等），后台折叠 + compaction 回收旧链 |
| **Managed DB**（2.0） | 调用方指定 readTs/commitTs（`openManaged/newTransactionAt/commitAt/setDiscardTs/newWriteBatchAt`） |
| **Sequence**（2.0） | 租约式单调递增序列（`getSequence`/`nextValue`/`release`） |
| **版本保留策略**（2.0） | compaction 按 `discardTs` + `numVersionsToKeep` 保留旧版本（活跃读者安全） |
| **EstimateSize**（2.0） | 按前缀估算 on-disk/解压后字节数 |
| **FORMAT 基线**（2.0） | 数据目录格式声明；旧目录缺失视为 v1.6.x 并在首次打开补写 |
| **Block Cache**（2.1） | 可配容量 LRU 缓存热 block（`blockCacheSizeMB`，默认关）；摘表即失效，命中率/占用见 `stats()` |
| **渐进式 arena**（2.2） | Pebble 式渐进扩容（`arenaGrowthStartBytes`）：首张 memtable 从小 arena 起步、逐轮翻倍，低堆首写不再按目标值一次性分配 |
| **流式落盘**（2.2） | `streamingSSTable`：flush/compaction 边构建边写文件（io_uring 分段提交，失败回退同步写），低堆下不再需要整表副本 |
| **运行统计**（2.2） | `db.getStats()`：读次数、flush/compaction 次数、memtable 用量、各层表数与字节数、块缓存命中/占用 |
| **表生命周期**（2.2） | 表按引用释放：compaction 换表不会解映射正在被迭代器读取的表（旧实现并发下可能抛 `MmapFile is closed`） |

### ⏳ 待完善

| 功能 | 说明 |
|------|------|
| Encryption | 加密存储：先定算法口径（SM4-CTR vs AES-256-CTR）再排期；当前默认 `Compression=None` + mmap 零拷贝，加密会引入额外的写路径开销 |

## 参考

- [BadgerDB v4](https://github.com/dgraph-io/badger) - 原始 Go 实现
- [LSM-Tree](https://www.cs.umb.edu/~poneil/lsmtree.pdf) - Log-Structured Merge-Tree

## 文档

- [基准测试](docs/benchmark-report.md) - 性能测试报告（v1.6.21 实测）
- [基准方法学](docs/benchmark-methodology.md) - 怎么测、哪些数字不能引用
- [进度跟踪](docs/progress-tracking.md) - 项目进度和实现细节
- [设计文档](docs/plans/) - 各阶段设计文档

## 相关项目

基于 badger-cj 的生态项目：

- [storm-cj](https://atomgit.com/ystyle/badger-storm): JSON 文档数据库
- [holt-cj](https://atomgit.com/ystyle/holt-cj): 图数据库
- [tsdb-cj](https://atomgit.com/ystyle/tsdb-cj): 时序数据库
- [sunku-cj](https://atomgit.com/ystyle/sunku-cj): 类 Redis 指令的缓存操作
