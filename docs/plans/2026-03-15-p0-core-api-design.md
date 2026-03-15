# P0 核心功能完善设计

**状态：✅ 已完成** (2026-03-15)

## 概述

实现 Badger-cj API 对齐的 P0 功能，包括异常类、Entry withMeta/withTTL/withDiscard、Item 完整 API、IteratorOptions 完整字段。

## 需求确认

| 功能项 | 决定 |
|--------|------|
| Item 懒加载 | 不需要，保持现有实现 |
| TTL 过期检查 | 读取时 + Compaction + GC 三处都实现 |
| withDiscard | 需要实现 |

---

## 1. BadgerException 异常类 ✅

### 实现

```cangjie
public enum ErrorCode {
    | DatabaseClosed
    | TransactionDiscarded
    | TransactionCommitted
    | ReadOnlyTransaction
    | ConflictDetected
    | KeyNotFound
    | IOError
    | CorruptionError
    | InvalidConfig
}

public class BadgerException <: Exception {
    public let code: ErrorCode
    
    public init(code: ErrorCode, message: String) { ... }
    
    public static func databaseClosed(): BadgerException { ... }
    public static func transactionDiscarded(): BadgerException { ... }
    public static func conflictDetected(): BadgerException { ... }
    // ...
}
```

### 文件

- `src/db/exception.cj`

---

## 2. Entry 类重构 ✅

### 关键设计决策

**分离 meta 和 userMeta**：

| 字段 | 用途 | 说明 |
|------|------|------|
| `meta` | 内部标记 | bitDelete, bitDiscardEarlierVersions 等 |
| `userMeta` | 用户自定义 | 用户可设置任意值（0x00-0xFF） |

**原因**：如果 userMeta 用于判断 isDelete()，用户设置 `withMeta(0x55)` 会触发误删（0x55 包含 bitDelete 位）。

### 实现

```cangjie
public class Entry {
    public let key: Array<Byte>
    public let value: Array<Byte>
    public let meta: Byte           // 内部标记（bitDelete, bitDiscardEarlierVersions）
    public let userMeta: Byte       // 用户自定义标记
    public let expiresAt: UInt64    // Unix timestamp (秒)
    
    public init(
        key: Array<Byte>, 
        value: Array<Byte>, 
        meta!: Byte = 0,
        userMeta!: Byte = 0, 
        expiresAt!: UInt64 = 0
    ) {
        this.key = key
        this.value = value
        this.meta = meta
        this.userMeta = userMeta
        this.expiresAt = expiresAt
    }
    
    public static func new(key: Array<Byte>, value: Array<Byte>): Entry {
        Entry(key, value)
    }
    
    public static func delete(key: Array<Byte>): Entry {
        Entry(key, [], meta: Meta.bitDelete)
    }
    
    public func withMeta(userMeta: Byte): Entry {
        Entry(key, value, meta: meta, userMeta: userMeta, expiresAt: expiresAt)
    }
    
    public func withTTL(dur: Duration): Entry {
        let now = DateTime.now().toUnixTimeStamp()
        Entry(key, value, meta: meta, userMeta: userMeta, 
              expiresAt: UInt64(now.toSeconds()) + UInt64(dur.toSeconds()))
    }
    
    public func withDiscard(): Entry {
        Entry(key, value, meta: meta | Meta.bitDiscardEarlierVersions, 
              userMeta: userMeta, expiresAt: expiresAt)
    }
    
    public func isDelete(): Bool {
        (meta & Meta.bitDelete) != 0
    }
}
```

### 说明

- `meta`: 内部标记，由 `withDiscard()` 和 `Entry.delete()` 设置
- `userMeta`: 用户自定义标记，由 `withMeta()` 设置，可以是任意值
- `withTTL`: 设置过期时间，Duration 转换为 Unix 时间戳
- `withDiscard`: 设置丢弃旧版本标记，修改 meta 字段

### 文件

- `src/db/entry.cj`

---

## 3. 写入路径改动 ✅

### 3.1 WriteEntry 添加字段

```cangjie
// write_request.cj
public struct WriteEntry {
    public let key: Array<Byte>
    public let value: Array<Byte>
    public let isDelete: Bool
    public let meta: Byte           // 内部标记
    public let userMeta: Byte       // 用户标记
    public let expiresAt: UInt64    // 过期时间
    
    public init(key: Array<Byte>, value: Array<Byte>, 
                isDelete: Bool, userMeta: Byte = 0, expiresAt: UInt64 = 0)
}

public class WriteRequest {
    public func addEntry(key: Array<Byte>, value: Array<Byte>, 
                         isDelete!: Bool = false, 
                         userMeta!: Byte = 0, 
                         expiresAt!: UInt64 = 0): Unit
}
```

### 3.2 badger.cj 写入逻辑

```cangjie
// writeRequests() 和 writeOneRequest() 中
for (entry in entries) {
    let vs = if (entry.isDelete) {
        ValueStruct([], meta: Meta.bitDelete, version: req.commitTs)
    } else if (let Some(vp) <- vpOpt) {
        ValueStruct(vp.encode(), meta: Meta.bitValuePointer, 
                    userMeta: entry.userMeta,     // 传递
                    expiresAt: entry.expiresAt,   // 传递
                    version: req.commitTs)
    } else {
        ValueStruct(entry.value, 
                    userMeta: entry.userMeta,     // 传递
                    expiresAt: entry.expiresAt,   // 传递
                    version: req.commitTs)
    }
}
```

### 3.3 Transaction 改动

```cangjie
// transaction.cj
public struct TxnEntry {
    public let key: Array<Byte>
    public let value: Array<Byte>
    public let meta: Byte
    public let userMeta: Byte       // 新增
    public let expiresAt: UInt64    // 新增
}

public func setEntry(e: Entry): Unit {
    if (!update) { throw BadgerException.readOnlyTransaction() }
    if (discarded) { throw BadgerException.transactionDiscarded() }
    
    addConflictKey(e.key)
    writes.add(TxnEntry(e.key, e.value, 
                        meta: if (e.userMeta & Meta.bitDelete != 0) { TxnMetaDelete } else { TxnMetaValue },
                        userMeta: e.userMeta,
                        expiresAt: e.expiresAt))
}
```

---

## 4. 读取路径 - 过期检查

### 4.1 辅助函数

```cangjie
// helpers.cj
public func isDeletedOrExpired(meta: Byte, expiresAt: UInt64): Bool {
    if ((meta & Meta.bitDelete) != 0) { return true }
    if (expiresAt == 0) { return false }
    let now = UInt64(DateTime.now().toUnixTimestamp())
    return expiresAt <= now
}
```

### 4.2 调用位置

**badger.cj:get()**
```cangjie
if (let Some(vs) <- mt.getWithTs(key, readTs)) {
    if (vs.isDelete() || isDeletedOrExpired(vs.meta, vs.expiresAt)) { 
        return None 
    }
    // ...
}
```

**iterator.cj:parseItem()**
```cangjie
if (let Some(vs) <- vsOpt) {
    if (vs.isDelete() || isDeletedOrExpired(vs.meta, vs.expiresAt)) {
        if (!opt.allVersions) {
            lastKey = safeCopy(lastKey, key)
        }
        iitr.next()
        continue
    }
}
```

**transaction.cj:get()**
```cangjie
let result = db.get(key, readTsOpt: Some(readTs))
if (let Some(vs) <- result) {
    if (isDeletedOrExpired(vs.meta, vs.expiresAt)) {
        return None
    }
    return Some(vs.value)
}
```

---

## 5. VLog GC - 过期丢弃

### 设计

```cangjie
// vlog_manager.cj 或 helpers.cj
public func discardEntry(entry: LogEntry, vs: ValueStruct): Bool {
    // 版本不匹配，丢弃
    if (vs.version != parseTs(entry.key)) { return true }
    // 已删除或过期，丢弃
    if (isDeletedOrExpired(vs.meta, vs.expiresAt)) { return true }
    // 值不在 VLog（存在 LSM），丢弃
    if ((vs.meta & Meta.bitValuePointer) == 0) { return true }
    return false
}
```

### 修改 GCFileRewriter

```cangjie
// vlog_manager.cj:rewrite() 中的迭代回调
file.iterate({ entry, offset =>
    let key = parseKey(entry.key)
    let vsOpt = gcDb.getVS(key)
    if (let Some(vs) <- vsOpt) {
        if (!discardEntry(entry, vs)) {
            rewriter.process(entry, offset)
        }
    }
})
```

---

## 6. Compaction - 过期过滤

### 设计

```cangjie
// compaction.cj:compactBuildTables()
for ((key, vs) in allEntries) {
    // 过期检查
    if (isDeletedOrExpired(vs.meta, vs.expiresAt)) {
        continue
    }
    
    if (lastKey.size == 0 || !sameKey(key, lastKey)) {
        builder.add(key, vs)
        lastKey = key
    }
}
```

---

## 7. Item 完整 API

### 设计

```cangjie
// item.cj
public class Item {
    // 已有字段...
    
    public func keyCopy(): Array<Byte> {
        Array<Byte>(key)
    }
    
    public func valueCopy(): Array<Byte> {
        Array<Byte>(value)
    }
    
    public func keySize(): Int64 {
        Int64(key.size)
    }
    
    public func valueSize(): Int64 {
        Int64(value.size)
    }
    
    public func discardEarlierVersions(): Bool {
        (meta & Meta.bitDiscardEarlierVersions) != 0
    }
    
    public func isDeletedOrExpired(): Bool {
        badgercj.db.isDeletedOrExpired(meta, expiresAt)
    }
    
    public func toString(): String {
        "Item(key=${bytesToHex(key)}, version=${version}, userMeta=${userMeta})"
    }
}
```

---

## 8. IteratorOptions 完整字段

### 设计

```cangjie
// iterator_options.cj
public class IteratorOptions {
    public var prefetchSize: Int
    public var prefetchValues: Bool
    public var reverse: Bool
    public var allVersions: Bool
    public var prefix: Array<Byte>
    public var sinceTs: UInt64
    
    public init(
        prefetchSize!: Int = 100,
        prefetchValues!: Bool = true,
        reverse!: Bool = false,
        allVersions!: Bool = false,
        prefix!: Array<Byte> = [],
        sinceTs!: UInt64 = 0
    ) {
        this.prefetchSize = prefetchSize
        this.prefetchValues = prefetchValues
        this.reverse = reverse
        this.allVersions = allVersions
        this.prefix = prefix
        this.sinceTs = sinceTs
    }
}

public let DefaultIteratorOptions = IteratorOptions()
```

---

## 改动文件清单

| 文件 | 改动类型 | 代码量 |
|------|----------|--------|
| `src/db/exception.cj` | 新建 | ~60 行 |
| `src/db/entry.cj` | 新建 | ~50 行 |
| `src/db/badger.cj` | 修改 Entry + 写入路径 | ~60 行 |
| `src/db/transaction.cj` | 修改 commit + get + setEntry | ~40 行 |
| `src/db/write_request.cj` | 添加字段 | ~25 行 |
| `src/db/helpers.cj` | 新增 isDeletedOrExpired, discardEntry | ~25 行 |
| `src/db/item.cj` | 添加方法 | ~40 行 |
| `src/db/iterator.cj` | 过期检查 | ~20 行 |
| `src/db/iterator_options.cj` | 新建完整类 | ~40 行 |
| `src/db/compaction.cj` | 过期过滤 | ~20 行 |
| `src/vlog/vlog_manager.cj` | GC 过期丢弃 | ~30 行 |
| 测试文件 | 新增/修改 | ~200 行 |
| **总计** | | **~610 行** |

---

## 测试计划

### 单元测试

1. **BadgerException**: 异常创建、错误码匹配
2. **Entry**: withMeta/withTTL/withDiscard 方法
3. **isDeletedOrExpired**: 边界条件（0、过去时间、未来时间）
4. **Item**: 所有新方法

### 集成测试

1. **TTL 写入读取**: 写入带 TTL 的数据，过期后读取返回 None
2. **TTL Compaction**: 过期数据在 Compaction 后被清理
3. **TTL GC**: 过期数据在 GC 后被清理
4. **withDiscard**: 设置后旧版本被丢弃

### 回归测试

运行现有所有测试，确保不影响现有功能。

---

## 风险点

1. **时间精度**: `DateTime.now().toUnixTimestamp()` 返回秒级，需确认精度
2. **性能**: 读取时每次检查过期会有轻微性能开销
3. **并发**: Compaction 和 GC 的过期检查需要考虑并发安全

---

## 工作量评估

| 任务 | 工作量 |
|------|--------|
| BadgerException | 0.5 天 |
| Entry 类 | 0.5 天 |
| 写入路径 | 1 天 |
| 读取路径 | 0.5 天 |
| VLog GC | 0.5 天 |
| Compaction | 0.5 天 |
| Item API | 0.5 天 |
| IteratorOptions | 0.5 天 |
| 测试 | 1 天 |
| **总计** | **5-6 天** |