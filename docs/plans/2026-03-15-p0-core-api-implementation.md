# P0 Core API Implementation Plan

**状态：✅ 已完成** (2026-03-15)

**Goal:** 实现 Badger-cj API 对齐的 P0 功能，包括异常类、Entry withMeta/withTTL/withDiscard、Item 完整 API、IteratorOptions 完整字段。

**Architecture:** 新增异常类和 Entry 类，修改写入/读取路径传递 userMeta/expiresAt，在读取、Compaction、GC 三处添加过期检查。

**Tech Stack:** 仓颉语言，std.time.DateTime，std.sync.Mutex

---

## 完成总结

| 任务 | 状态 | 提交 |
|------|------|------|
| Task 1: BadgerException | ✅ | c03c9da |
| Task 2: Entry 重构 | ✅ | 74ca804 |
| Task 3: WriteEntry 扩展 | ✅ | 95ffa1c |
| Task 4: isDeletedOrExpired | ✅ | c4c74aa |
| Task 5: 读取路径过期检查 | ✅ | b9adb65 |
| Task 6: 写入路径传递 | ✅ | 445da0b |
| Task 7: Compaction 过期过滤 | ✅ | a78af8f |
| Task 8: VLog GC 过期丢弃 | ✅ | d529e3b |
| Task 9: Item 完整 API | ✅ | 279a144 |
| Task 10: IteratorOptions | ✅ | 10058a6 |
| Task 11: 测试验证 | ✅ | 230 个测试通过 |

### 关键修复

**Entry.meta 和 Entry.userMeta 分离** (9709d26)：
- `meta`: 内部标记（bitDelete, bitDiscardEarlierVersions）
- `userMeta`: 用户自定义标记（用户可设置任意值）

### 新增测试

- `src/db/ttl_e2e_test.cj` - 10 个 TTL 端到端测试
- `src/db/entry_test.cj` - Entry API 测试
- `src/db/item_api_test.cj` - Item API 测试

---

## Task 1: BadgerException 异常类

**Files:**
- Create: `src/db/exception.cj`
- Test: `src/db/exception_test.cj`

**Step 1: Write the failing test**

```cangjie
// src/db/exception_test.cj
package badgercj.db

@Test
class ExceptionTest {
    @TestCase
    func testErrorCode() {
        let e = BadgerException.databaseClosed()
        @Assert(e.code, ErrorCode.DatabaseClosed)
    }
    
    @TestCase
    func testExceptionMessage() {
        let e = BadgerException.conflictDetected()
        @Assert(e.message.contains("conflict"), true)
    }
    
    @TestCase
    func testInvalidConfig() {
        let e = BadgerException.invalidConfig("bad dir")
        @Assert(e.code, ErrorCode.InvalidConfig)
        @Assert(e.message.contains("bad dir"), true)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cjpm test --filter 'ExceptionTest.*'`
Expected: FAIL with "BadgerException not found"

**Step 3: Write implementation**

```cangjie
// src/db/exception.cj
package badgercj.db

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
    
    public init(code: ErrorCode, message: String) {
        super(message)
        this.code = code
    }
    
    public static func databaseClosed(): BadgerException {
        BadgerException(ErrorCode.DatabaseClosed, "database is closed")
    }
    
    public static func transactionDiscarded(): BadgerException {
        BadgerException(ErrorCode.TransactionDiscarded, "transaction has been discarded")
    }
    
    public static func transactionCommitted(): BadgerException {
        BadgerException(ErrorCode.TransactionCommitted, "transaction has been committed")
    }
    
    public static func readOnlyTransaction(): BadgerException {
        BadgerException(ErrorCode.ReadOnlyTransaction, "read-only transaction")
    }
    
    public static func conflictDetected(): BadgerException {
        BadgerException(ErrorCode.ConflictDetected, "transaction conflict detected")
    }
    
    public static func keyNotFound(): BadgerException {
        BadgerException(ErrorCode.KeyNotFound, "key not found")
    }
    
    public static func ioError(msg: String): BadgerException {
        BadgerException(ErrorCode.IOError, msg)
    }
    
    public static func corruptionError(msg: String): BadgerException {
        BadgerException(ErrorCode.CorruptionError, msg)
    }
    
    public static func invalidConfig(msg: String): BadgerException {
        BadgerException(ErrorCode.InvalidConfig, msg)
    }
}
```

**Step 4: Run test to verify it passes**

Run: `cjpm test --filter 'ExceptionTest.*'`
Expected: PASS

**Step 5: Commit**

```bash
git add src/db/exception.cj src/db/exception_test.cj
git commit -m "feat: add BadgerException and ErrorCode"
```

---

## Task 2: Entry 类重构

**Files:**
- Create: `src/db/entry.cj`
- Modify: `src/db/badger.cj` (删除旧 Entry 定义)
- Test: `src/db/entry_test.cj`

**Step 1: Write the failing test**

```cangjie
// src/db/entry_test.cj
package badgercj.db

import std.time.*

@Test
class EntryTest {
    @TestCase
    func testBasicEntry() {
        let e = Entry("key".toArray(), "value".toArray())
        @Assert(e.key, "key".toArray())
        @Assert(e.value, "value".toArray())
        @Assert(e.userMeta, 0)
        @Assert(e.expiresAt, 0u64)
    }
    
    @TestCase
    func testWithMeta() {
        let e = Entry("key".toArray(), "value".toArray())
            .withMeta(0x01)
        @Assert(e.userMeta, 0x01)
    }
    
    @TestCase
    func testWithTTL() {
        let e = Entry("key".toArray(), "value".toArray())
            .withTTL(Duration.hour * 24)
        @Assert(e.expiresAt > 0u64, true)
    }
    
    @TestCase
    func testWithDiscard() {
        let e = Entry("key".toArray(), "value".toArray())
            .withDiscard()
        @Assert((e.userMeta & Meta.bitDiscardEarlierVersions) != 0, true)
    }
    
    @TestCase
    func testChainedWith() {
        let e = Entry("key".toArray(), "value".toArray())
            .withMeta(0x01)
            .withTTL(Duration.hour)
        @Assert(e.userMeta, 0x01)
        @Assert(e.expiresAt > 0u64, true)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cjpm test --filter 'EntryTest.*'`
Expected: FAIL with "Entry not found" 或类型不匹配

**Step 3: Write implementation**

```cangjie
// src/db/entry.cj
package badgercj.db

import std.time.*
import badgercj.table.Meta

public class Entry {
    public let key: Array<Byte>
    public let value: Array<Byte>
    public let userMeta: Byte
    public let expiresAt: UInt64
    
    public init(
        key: Array<Byte>, 
        value: Array<Byte>, 
        userMeta!: Byte = 0, 
        expiresAt!: UInt64 = 0
    ) {
        this.key = key
        this.value = value
        this.userMeta = userMeta
        this.expiresAt = expiresAt
    }
    
    public func withMeta(meta: Byte): Entry {
        Entry(key, value, userMeta: meta, expiresAt: expiresAt)
    }
    
    public func withTTL(dur: Duration): Entry {
        let now = UInt64(DateTime.now().toUnixTimestamp())
        Entry(key, value, userMeta: userMeta, expiresAt: now + UInt64(dur.toSeconds()))
    }
    
    public func withDiscard(): Entry {
        Entry(key, value, userMeta: userMeta | Meta.bitDiscardEarlierVersions, expiresAt: expiresAt)
    }
}

public func newEntry(key: Array<Byte>, value: Array<Byte>): Entry {
    Entry(key, value)
}

public func newDeleteEntry(key: Array<Byte>): Entry {
    Entry(key, [], userMeta: Meta.bitDelete)
}
```

**Step 4: Modify badger.cj to remove old Entry**

删除 `src/db/badger.cj` 中的旧 Entry 定义（第 12-22 行）：

```cangjie
// 删除以下代码：
public class Entry {
    public let key: Array<Byte>
    public let value: Array<Byte>
    public let isDelete: Bool
    
    public init(key: Array<Byte>, value: Array<Byte>, isDelete!: Bool = false) {
        this.key = key
        this.value = value
        this.isDelete = isDelete
    }
}
```

**Step 5: Run test to verify it passes**

Run: `cjpm test --filter 'EntryTest.*'`
Expected: PASS

**Step 6: Commit**

```bash
git add src/db/entry.cj src/db/entry_test.cj src/db/badger.cj
git commit -m "feat: refactor Entry with withMeta/withTTL/withDiscard"
```

---

## Task 3: WriteEntry 添加字段

**Files:**
- Modify: `src/db/write_request.cj`
- Test: `src/db/write_request_test.cj`

**Step 1: Write the failing test**

```cangjie
// src/db/write_request_test.cj
package badgercj.db

@Test
class WriteRequestTest {
    @TestCase
    func testWriteEntryWithMeta() {
        let entry = WriteEntry("key".toArray(), "value".toArray(), 
                               isDelete: false, userMeta: 0x01, expiresAt: 12345u64)
        @Assert(entry.userMeta, 0x01)
        @Assert(entry.expiresAt, 12345u64)
    }
    
    @TestCase
    func testAddEntryWithMeta() {
        let req = WriteRequest(1u64)
        req.addEntry("key".toArray(), "value".toArray(), 
                     isDelete: false, userMeta: 0x02, expiresAt: 99999u64)
        let entries = req.getEntries()
        @Assert(entries.size, 1)
        @Assert(entries[0].userMeta, 0x02)
        @Assert(entries[0].expiresAt, 99999u64)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cjpm test --filter 'WriteRequestTest.*'`
Expected: FAIL with "userMeta not found"

**Step 3: Write implementation**

```cangjie
// src/db/write_request.cj - 修改 WriteEntry 结构体
public struct WriteEntry {
    public let key: Array<Byte>
    public let value: Array<Byte>
    public let isDelete: Bool
    public let userMeta: Byte
    public let expiresAt: UInt64
    
    public init(
        key: Array<Byte>, 
        value: Array<Byte>, 
        isDelete: Bool, 
        userMeta!: Byte = 0, 
        expiresAt!: UInt64 = 0
    ) {
        this.key = key
        this.value = value
        this.isDelete = isDelete
        this.userMeta = userMeta
        this.expiresAt = expiresAt
    }
}

// 修改 addEntry 方法
public func addEntry(
    key: Array<Byte>, 
    value: Array<Byte>, 
    isDelete!: Bool = false, 
    userMeta!: Byte = 0, 
    expiresAt!: UInt64 = 0
): Unit {
    entries.add(WriteEntry(key, value, isDelete: isDelete, 
                           userMeta: userMeta, expiresAt: expiresAt))
}
```

**Step 4: Run test to verify it passes**

Run: `cjpm test --filter 'WriteRequestTest.*'`
Expected: PASS

**Step 5: Commit**

```bash
git add src/db/write_request.cj src/db/write_request_test.cj
git commit -m "feat: add userMeta and expiresAt to WriteEntry"
```

---

## Task 4: isDeletedOrExpired 辅助函数

**Files:**
- Modify: `src/db/helpers.cj`
- Test: `src/db/helpers_test.cj`

**Step 1: Write the failing test**

```cangjie
// src/db/helpers_test.cj
package badgercj.db

import badgercj.table.Meta

@Test
class HelpersTest {
    @TestCase
    func testNotExpired() {
        @Assert(isDeletedOrExpired(0, 0), false)
    }
    
    @TestCase
    func testDeleted() {
        @Assert(isDeletedOrExpired(Meta.bitDelete, 0), true)
    }
    
    @TestCase
    func testExpired() {
        let pastTime = UInt64(DateTime.now().toUnixTimestamp()) - 100u64
        @Assert(isDeletedOrExpired(0, pastTime), true)
    }
    
    @TestCase
    func testNotExpiredYet() {
        let futureTime = UInt64(DateTime.now().toUnixTimestamp()) + 10000u64
        @Assert(isDeletedOrExpired(0, futureTime), false)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cjpm test --filter 'HelpersTest.*'`
Expected: FAIL with "isDeletedOrExpired not found"

**Step 3: Write implementation**

```cangjie
// src/db/helpers.cj - 添加函数
public func isDeletedOrExpired(meta: Byte, expiresAt: UInt64): Bool {
    if ((meta & Meta.bitDelete) != 0) { return true }
    if (expiresAt == 0) { return false }
    let now = UInt64(DateTime.now().toUnixTimestamp())
    return expiresAt <= now
}
```

**Step 4: Run test to verify it passes**

Run: `cjpm test --filter 'HelpersTest.*'`
Expected: PASS

**Step 5: Commit**

```bash
git add src/db/helpers.cj src/db/helpers_test.cj
git commit -m "feat: add isDeletedOrExpired helper function"
```

---

## Task 5: 读取路径过期检查

**Files:**
- Modify: `src/db/badger.cj`
- Modify: `src/db/transaction.cj`
- Modify: `src/db/iterator.cj`

**Step 1: Write the failing test**

```cangjie
// src/db/ttl_test.cj
package badgercj.db

import std.time.*

@Test
class TTLTest {
    @TestCase
    func testExpiredKeyReturnsNone() {
        let dir = "/tmp/badger_ttl_test_1"
        let db = Badger.open(Config(dir: dir, memTableSize: 1024 * 1024))
        
        // 写入已过期的数据
        let pastTime = UInt64(DateTime.now().toUnixTimestamp()) - 100u64
        let entry = Entry("key1".toArray(), "value1".toArray(), expiresAt: pastTime)
        db.batchSet([entry])
        
        // 读取应返回 None
        let result = db.get("key1".toArray())
        @Assert(result.isNone(), true)
        
        db.close()
    }
    
    @TestCase
    func testNotExpiredKeyReturnsValue() {
        let dir = "/tmp/badger_ttl_test_2"
        let db = Badger.open(Config(dir: dir, memTableSize: 1024 * 1024))
        
        // 写入未过期的数据
        let futureTime = UInt64(DateTime.now().toUnixTimestamp()) + 10000u64
        let entry = Entry("key2".toArray(), "value2".toArray(), expiresAt: futureTime)
        db.batchSet([entry])
        
        // 读取应返回值
        if (let Some(vs) <- db.get("key2".toArray())) {
            @Assert(vs.value, "value2".toArray())
        } else {
            @Fail("expected value")
        }
        
        db.close()
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cjpm test --filter 'TTLTest.testExpiredKeyReturnsNone'`
Expected: FAIL - 过期数据仍被返回

**Step 3: Modify badger.cj get()**

```cangjie
// src/db/badger.cj - get() 方法中添加过期检查
public func get(key: Array<Byte>, readTsOpt!: ?UInt64 = None): Option<ValueStruct> {
    lock.readLock.lock()
    try {
        let readTs = readTsOpt ?? oracle.currentTs()
        
        // Check memtable
        if (let Some(vs) <- mt.getWithTs(key, readTs)) {
            if (vs.isDelete() || isDeletedOrExpired(vs.meta, vs.expiresAt)) { 
                return None 
            }
            if (vs.isValuePointer()) {
                let vp = ValuePointer.decode(vs.value)
                let entry = vlog.read(vp)
                return Some(ValueStruct(entry.value, meta: 0, version: vs.version))
            }
            return Some(vs)
        }
        
        // Check immutable memtables
        for (i in 0..imm.size) {
            let immMt = imm[imm.size - 1 - i]
            if (let Some(vs) <- immMt.getWithTs(key, readTs)) {
                if (vs.isDelete() || isDeletedOrExpired(vs.meta, vs.expiresAt)) { 
                    return None 
                }
                if (vs.isValuePointer()) {
                    let vp = ValuePointer.decode(vs.value)
                    let entry = vlog.read(vp)
                    return Some(ValueStruct(entry.value, meta: 0, version: vs.version))
                }
                return Some(vs)
            }
        }
        
        // Check levels
        if (let Some(vs) <- lc.get(key, readTs)) {
            if (vs.isDelete() || isDeletedOrExpired(vs.meta, vs.expiresAt)) { 
                return None 
            }
            if (vs.isValuePointer()) {
                let vp = ValuePointer.decode(vs.value)
                let entry = vlog.read(vp)
                return Some(ValueStruct(entry.value, meta: 0, version: vs.version))
            }
            return Some(vs)
        }
        
        return None
    } finally {
        lock.readLock.unlock()
    }
}
```

**Step 4: Modify transaction.cj get()**

```cangjie
// src/db/transaction.cj - get() 方法中添加过期检查
public func get(key: Array<Byte>): Option<Array<Byte>> {
    if (discarded) {
        throw Exception("Transaction discarded")
    }
    
    for (entry in writes) {
        if (keysEqual(entry.key, key)) {
            if (entry.isDelete()) {
                return None
            }
            return Some(entry.value)
        }
    }
    
    addReadKey(key)
    
    let result = db.get(key, readTsOpt: Some(readTs))
    if (result.isSome()) {
        if (let Some(vs) <- result) {
            if (isDeletedOrExpired(vs.meta, vs.expiresAt)) {
                return None
            }
            return Some(vs.value)
        }
    }
    
    return None
}
```

**Step 5: Modify iterator.cj parseItem()**

```cangjie
// src/db/iterator.cj - parseItem() 方法中添加过期检查
// 在检查 vs.isDelete() 的地方添加过期检查
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

**Step 6: Run test to verify it passes**

Run: `cjpm test --filter 'TTLTest.*'`
Expected: PASS

**Step 7: Commit**

```bash
git add src/db/badger.cj src/db/transaction.cj src/db/iterator.cj src/db/ttl_test.cj
git commit -m "feat: add TTL expiration check in read path"
```

---

## Task 6: 写入路径传递 userMeta/expiresAt

**Files:**
- Modify: `src/db/badger.cj`
- Modify: `src/db/transaction.cj`

**Step 1: Write the failing test**

```cangjie
// src/db/usermeta_test.cj
package badgercj.db

@Test
class UserMetaTest {
    @TestCase
    func testUserMetaPreserved() {
        let dir = "/tmp/badger_usermeta_test_1"
        let db = Badger.open(Config(dir: dir, memTableSize: 1024 * 1024))
        
        let entry = Entry("key1".toArray(), "value1".toArray(), userMeta: 0x42)
        db.batchSet([entry])
        
        // 通过迭代器检查 userMeta
        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator()
        iter.rewind()
        
        if (iter.valid()) {
            let item = iter.item()
            @Assert(item.userMeta, 0x42)
        } else {
            @Fail("expected item")
        }
        
        iter.close()
        txn.discard()
        db.close()
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cjpm test --filter 'UserMetaTest.*'`
Expected: FAIL - userMeta 为 0

**Step 3: Modify badger.cj writeRequests()**

```cangjie
// src/db/badger.cj - writeRequests() 方法
for (entry in entries) {
    let vpOpt: Option<ValuePointer> = if (UInt64(entry.value.size) >= opt.ValueThreshold && !entry.isDelete) {
        Some(vlog.write(LogEntry(entry.key, entry.value, meta: entry.userMeta, expiresAt: entry.expiresAt)))
    } else {
        None
    }
    
    let keyWithTs = keyWithTs(entry.key, req.commitTs)
    let vs = if (entry.isDelete) {
        ValueStruct([], meta: Meta.bitDelete, version: req.commitTs)
    } else if (let Some(vp) <- vpOpt) {
        ValueStruct(vp.encode(), meta: Meta.bitValuePointer, 
                    userMeta: entry.userMeta, expiresAt: entry.expiresAt, version: req.commitTs)
    } else {
        ValueStruct(entry.value, meta: 0, 
                    userMeta: entry.userMeta, expiresAt: entry.expiresAt, version: req.commitTs)
    }
    mt.put(keyWithTs, vs)
}
```

**Step 4: Modify transaction.cj TxnEntry and commit()**

```cangjie
// src/db/transaction.cj - 修改 TxnEntry
public struct TxnEntry {
    public let key: Array<Byte>
    public let value: Array<Byte>
    public let meta: Byte
    public let userMeta: Byte
    public let expiresAt: UInt64
    
    public init(key: Array<Byte>, value: Array<Byte>, meta: Byte, 
                userMeta!: Byte = 0, expiresAt!: UInt64 = 0) {
        this.key = key
        this.value = value
        this.meta = meta
        this.userMeta = userMeta
        this.expiresAt = expiresAt
    }
    
    public func isDelete(): Bool {
        return meta == TxnMetaDelete
    }
}

// 添加 setEntry 方法
public func setEntry(e: Entry): Unit {
    if (!update) {
        throw BadgerException.readOnlyTransaction()
    }
    if (discarded) {
        throw BadgerException.transactionDiscarded()
    }
    
    addConflictKey(e.key)
    let meta = if ((e.userMeta & Meta.bitDelete) != 0) { TxnMetaDelete } else { TxnMetaValue }
    writes.add(TxnEntry(e.key, e.value, meta: meta, userMeta: e.userMeta, expiresAt: e.expiresAt))
}

// 修改 commit() 传递 userMeta/expiresAt
public func commit(): Unit {
    // ... existing code ...
    
    let req = db.reqPool.get(commitTs)
    for (entry in writes) {
        req.addEntry(entry.key, entry.value, isDelete: entry.isDelete(), 
                     userMeta: entry.userMeta, expiresAt: entry.expiresAt)
    }
    
    // ... rest of commit ...
}
```

**Step 5: Run test to verify it passes**

Run: `cjpm test --filter 'UserMetaTest.*'`
Expected: PASS

**Step 6: Commit**

```bash
git add src/db/badger.cj src/db/transaction.cj src/db/usermeta_test.cj
git commit -m "feat: pass userMeta and expiresAt through write path"
```

---

## Task 7: Compaction 过期过滤

**Files:**
- Modify: `src/db/compaction.cj`
- Test: `src/db/compaction_test.cj` (添加 TTL 测试)

**Step 1: Write the failing test**

```cangjie
// 在 src/db/compaction_test.cj 添加测试
@TestCase
func testCompactionFiltersExpired(): Unit {
    let dir = "/tmp/badger_compaction_ttl_test"
    let db = Badger.open(Config(dir: dir, memTableSize: 1024 * 1024))
    
    // 写入已过期数据
    let pastTime = UInt64(DateTime.now().toUnixTimestamp()) - 100u64
    let entry1 = Entry("expired_key".toArray(), "value".toArray(), expiresAt: pastTime)
    let entry2 = Entry("valid_key".toArray(), "value".toArray())
    db.batchSet([entry1, entry2])
    
    // 强制 flush
    db.flushMemTable()
    
    // 运行 compaction
    db.compact()
    
    // 过期数据应被清理
    @Assert(db.get("expired_key".toArray()).isNone(), true)
    @Assert(db.get("valid_key".toArray()).isSome(), true)
    
    db.close()
}
```

**Step 2: Run test to verify it fails**

Run: `cjpm test --filter 'CompactionTest.testCompactionFiltersExpired'`
Expected: FAIL - 过期数据仍存在

**Step 3: Modify compaction.cj compactBuildTables()**

```cangjie
// src/db/compaction.cj - compactBuildTables() 方法
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

**Step 4: Run test to verify it passes**

Run: `cjpm test --filter 'CompactionTest.testCompactionFiltersExpired'`
Expected: PASS

**Step 5: Commit**

```bash
git add src/db/compaction.cj
git commit -m "feat: filter expired entries in compaction"
```

---

## Task 8: VLog GC 过期丢弃

**Files:**
- Modify: `src/vlog/vlog_manager.cj`
- Test: `src/vlog/vlog_gc_test.cj` (添加 TTL 测试)

**Step 1: Write the failing test**

```cangjie
// 在 src/vlog/vlog_gc_test.cj 添加测试
@TestCase
func testGCDiscardsExpired(): Unit {
    let dir = "/tmp/badger_vlog_gc_ttl_test"
    let db = Badger.open(Config(dir: dir, memTableSize: 1024 * 1024, valueThreshold: 10))
    
    // 写入大值（触发 VLog）+ 已过期
    let pastTime = UInt64(DateTime.now().toUnixTimestamp()) - 100u64
    let largeValue = Array<Byte>(1000, repeat: 0x41)
    let entry1 = Entry("expired_large".toArray(), largeValue, expiresAt: pastTime)
    let entry2 = Entry("valid_large".toArray(), largeValue)
    db.batchSet([entry1, entry2])
    
    // 强制 flush
    db.flushMemTable()
    
    // 运行 GC
    db.runVLogGC(0.5)
    
    // 过期数据应被清理
    @Assert(db.get("expired_large".toArray()).isNone(), true)
    @Assert(db.get("valid_large".toArray()).isSome(), true)
    
    db.close()
}
```

**Step 2: Run test to verify it fails**

Run: `cjpm test --filter 'VLogGCTest.testGCDiscardsExpired'`
Expected: FAIL - 过期数据仍存在

**Step 3: Add discardEntry function**

```cangjie
// src/db/helpers.cj - 添加 discardEntry 函数
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

**Step 4: Modify vlog_manager.cj rewrite()**

```cangjie
// src/vlog/vlog_manager.cj - rewrite() 方法中的迭代回调
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

**Step 5: Run test to verify it passes**

Run: `cjpm test --filter 'VLogGCTest.testGCDiscardsExpired'`
Expected: PASS

**Step 6: Commit**

```bash
git add src/db/helpers.cj src/vlog/vlog_manager.cj
git commit -m "feat: discard expired entries in VLog GC"
```

---

## Task 9: Item 完整 API

**Files:**
- Modify: `src/db/item.cj`
- Test: `src/db/item_test.cj`

**Step 1: Write the failing test**

```cangjie
// src/db/item_test.cj
package badgercj.db

import badgercj.table.Meta

@Test
class ItemTest {
    @TestCase
    func testKeyCopy() {
        let item = Item("key".toArray(), "value".toArray())
        let copy = item.keyCopy()
        @Assert(copy, "key".toArray())
    }
    
    @TestCase
    func testValueCopy() {
        let item = Item("key".toArray(), "value".toArray())
        let copy = item.valueCopy()
        @Assert(copy, "value".toArray())
    }
    
    @TestCase
    func testKeySize() {
        let item = Item("hello".toArray(), "world".toArray())
        @Assert(item.keySize(), 5)
    }
    
    @TestCase
    func testValueSize() {
        let item = Item("hi".toArray(), "world".toArray())
        @Assert(item.valueSize(), 5)
    }
    
    @TestCase
    func testDiscardEarlierVersions() {
        let item = Item("key".toArray(), "value".toArray(), meta: Meta.bitDiscardEarlierVersions)
        @Assert(item.discardEarlierVersions(), true)
    }
    
    @TestCase
    func testNotDiscardEarlierVersions() {
        let item = Item("key".toArray(), "value".toArray(), meta: 0)
        @Assert(item.discardEarlierVersions(), false)
    }
    
    @TestCase
    func testIsDeletedOrExpired() {
        let pastTime = UInt64(DateTime.now().toUnixTimestamp()) - 100u64
        let item = Item("key".toArray(), "value".toArray(), expiresAt: pastTime)
        @Assert(item.isDeletedOrExpired(), true)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cjpm test --filter 'ItemTest.*'`
Expected: FAIL with "method not found"

**Step 3: Write implementation**

```cangjie
// src/db/item.cj - 添加方法
public func keyCopy(): Array<Byte> {
    let copy = Array<Byte>(key.size, repeat: 0)
    for (i in 0..key.size) {
        copy[i] = key[i]
    }
    return copy
}

public func valueCopy(): Array<Byte> {
    let copy = Array<Byte>(value.size, repeat: 0)
    for (i in 0..value.size) {
        copy[i] = value[i]
    }
    return copy
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
    let keyHex = bytesToHex(key)
    "Item(key=${keyHex}, version=${version}, userMeta=${userMeta})"
}

private func bytesToHex(bytes: Array<Byte>): String {
    let hexChars = "0123456789abcdef"
    var result = ""
    for (b in bytes) {
        result += String(hexChars[Int64((b >> 4) & 0x0F)])
        result += String(hexChars[Int64(b & 0x0F)])
    }
    result
}
```

**Step 4: Run test to verify it passes**

Run: `cjpm test --filter 'ItemTest.*'`
Expected: PASS

**Step 5: Commit**

```bash
git add src/db/item.cj src/db/item_test.cj
git commit -m "feat: add complete Item API methods"
```

---

## Task 10: IteratorOptions 完整字段

**Files:**
- Create: `src/db/iterator_options.cj`
- Modify: `src/db/iterator.cj` (导入新类)
- Test: `src/db/iterator_options_test.cj`

**Step 1: Write the failing test**

```cangjie
// src/db/iterator_options_test.cj
package badgercj.db

@Test
class IteratorOptionsTest {
    @TestCase
    func testDefaultOptions() {
        let opt = DefaultIteratorOptions
        @Assert(opt.prefetchSize, 100)
        @Assert(opt.prefetchValues, true)
        @Assert(opt.reverse, false)
        @Assert(opt.allVersions, false)
        @Assert(opt.sinceTs, 0u64)
    }
    
    @TestCase
    func testCustomOptions() {
        let opt = IteratorOptions(
            prefetchSize: 200,
            prefetchValues: false,
            reverse: true,
            allVersions: true,
            prefix: "test".toArray(),
            sinceTs: 12345u64
        )
        @Assert(opt.prefetchSize, 200)
        @Assert(opt.prefetchValues, false)
        @Assert(opt.reverse, true)
        @Assert(opt.allVersions, true)
        @Assert(opt.sinceTs, 12345u64)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cjpm test --filter 'IteratorOptionsTest.*'`
Expected: FAIL with "IteratorOptions not found"

**Step 3: Write implementation**

```cangjie
// src/db/iterator_options.cj
package badgercj.db

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

**Step 4: Update iterator.cj import**

```cangjie
// src/db/iterator.cj - 确保导入 IteratorOptions
// 如果之前在 iterator.cj 中定义了 IteratorOptions，删除它
```

**Step 5: Run test to verify it passes**

Run: `cjpm test --filter 'IteratorOptionsTest.*'`
Expected: PASS

**Step 6: Commit**

```bash
git add src/db/iterator_options.cj src/db/iterator_options_test.cj src/db/iterator.cj
git commit -m "feat: add complete IteratorOptions with all fields"
```

---

## Task 11: 运行所有测试

**Step 1: Run all tests**

Run: `cjpm test -j 16 --no-progress`
Expected: All tests PASS

**Step 2: Run build**

Run: `cjpm build -j 16`
Expected: Build successful

**Step 3: Final commit if needed**

```bash
git status
# 如果有未提交的更改
git add -A
git commit -m "chore: final cleanup for P0 implementation"
```

---

## Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | BadgerException | exception.cj |
| 2 | Entry refactor | entry.cj, badger.cj |
| 3 | WriteEntry fields | write_request.cj |
| 4 | isDeletedOrExpired | helpers.cj |
| 5 | Read path TTL check | badger.cj, transaction.cj, iterator.cj |
| 6 | Write path userMeta/expiresAt | badger.cj, transaction.cj |
| 7 | Compaction TTL filter | compaction.cj |
| 8 | VLog GC TTL discard | vlog_manager.cj |
| 9 | Item API | item.cj |
| 10 | IteratorOptions | iterator_options.cj |
| 11 | Final testing | all |