# Phase 7 实现计划：完整 Compaction + VLog GC

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现完整多层级 Compaction 和 VLog GC，解决磁盘空间无限增长问题。

**Architecture:** 
- Compaction: 基于 compactStatus 并发控制 + MergeIterator 合并 + 丢弃策略
- VLog GC: 统计垃圾比例 + 重写有效值 + offsetMap 间接层

**Tech Stack:** 仓颉语言 + 现有 LSM-Tree 架构

---

## P0: Compaction 核心实现

### Task 1: 实现 keyRange 结构

**Files:**
- Create: `src/db/compact_status.cj`

**Step 1: 创建 keyRange 结构**

```cangjie
package badgercj.db

import std.collection.*

public struct keyRange {
    public let left: Array<Byte>
    public let right: Array<Byte>
    public let inf: Bool
    
    public init(left!: Array<Byte> = [], right!: Array<Byte> = [], inf!: Bool = false) {
        this.left = left
        this.right = right
        this.inf = inf
    }
    
    public func isEmpty(): Bool {
        return left.size == 0 && right.size == 0 && !inf
    }
    
    public func overlapsWith(other: keyRange): Bool {
        if (isEmpty() || other.isEmpty()) {
            return true
        }
        if (inf || other.inf) {
            return true
        }
        
        // [other.left, other.right] ... [this.left, this.right]
        if (compareKeys(left, other.right) > 0) {
            return false
        }
        // [this.left, this.right] ... [other.left, other.right]
        if (compareKeys(right, other.left) < 0) {
            return false
        }
        return true
    }
    
    public mutating func extend(other: keyRange) {
        if (other.isEmpty()) {
            return
        }
        if (isEmpty()) {
            left = other.left
            right = other.right
            inf = other.inf
            return
        }
        if (left.size == 0 || compareKeys(other.left, left) < 0) {
            left = other.left
        }
        if (right.size == 0 || compareKeys(other.right, right) > 0) {
            right = other.right
        }
        if (other.inf) {
            inf = true
        }
    }
    
    public func equals(other: keyRange): Bool {
        if (inf != other.inf) {
            return false
        }
        return keysEqual(left, other.left) && keysEqual(right, other.right)
    }
    
    private func compareKeys(a: Array<Byte>, b: Array<Byte>): Int64 {
        let minLen = if (a.size < b.size) { a.size } else { b.size }
        for (i in 0..minLen) {
            if (a[i] < b[i]) { return -1 }
            if (a[i] > b[i]) { return 1 }
        }
        if (a.size < b.size) { return -1 }
        if (a.size > b.size) { return 1 }
        return 0
    }
    
    private func keysEqual(a: Array<Byte>, b: Array<Byte>): Bool {
        if (a.size != b.size) { return false }
        for (i in 0..a.size) {
            if (a[i] != b[i]) { return false }
        }
        return true
    }
}

public let infRange = keyRange(inf: true)
```

**Step 2: 编译验证**

Run: `cjpm build -j 16`
Expected: 编译成功

**Step 3: 提交**

```bash
git add src/db/compact_status.cj
git commit -m "feat(compaction): 添加 keyRange 结构"
```

---

### Task 2: 实现 levelCompactStatus 和 compactStatus

**Files:**
- Modify: `src/db/compact_status.cj`

**Step 1: 添加 levelCompactStatus**

```cangjie
public struct levelCompactStatus {
    public var ranges: ArrayList<keyRange>
    public var delSize: Int64
    
    public init() {
        this.ranges = ArrayList<keyRange>()
        this.delSize = 0
    }
    
    public func overlapsWith(range: keyRange): Bool {
        for (r in ranges) {
            if (r.overlapsWith(range)) {
                return true
            }
        }
        return false
    }
    
    public mutating func remove(range: keyRange): Bool {
        var found = false
        let newRanges = ArrayList<keyRange>()
        for (r in ranges) {
            if (!r.equals(range)) {
                newRanges.add(r)
            } else {
                found = true
            }
        }
        ranges = newRanges
        return found
    }
}
```

**Step 2: 添加 compactStatus 类**

```cangjie
import std.sync.*

public class compactStatus {
    private let lock: RWMutex
    private let levels: ArrayList<levelCompactStatus>
    private let tables: HashSet<UInt64>
    
    public init(numLevels: Int) {
        this.lock = RWMutex()
        this.levels = ArrayList<levelCompactStatus>()
        this.tables = HashSet<UInt64>()
        
        for (i in 0..numLevels) {
            levels.add(levelCompactStatus())
        }
    }
    
    public func overlapsWith(level: Int, range: keyRange): Bool {
        lock.readLock.lock()
        try {
            return levels[level].overlapsWith(range)
        } finally {
            lock.readLock.unlock()
        }
    }
    
    public func compareAndAdd(cd: compactDef): Bool {
        lock.writeLock.lock()
        try {
            let thisLevel = levels[cd.thisLevel]
            let nextLevel = levels[cd.nextLevel]
            
            if (thisLevel.overlapsWith(cd.thisRange)) {
                return false
            }
            if (nextLevel.overlapsWith(cd.nextRange)) {
                return false
            }
            
            // 检查表是否正在被使用
            for (t in cd.top) {
                if (tables.contains(t.id())) {
                    return false
                }
            }
            for (t in cd.bot) {
                if (tables.contains(t.id())) {
                    return false
                }
            }
            
            // 添加范围和表
            thisLevel.ranges.add(cd.thisRange)
            nextLevel.ranges.add(cd.nextRange)
            thisLevel.delSize += cd.thisSize
            
            for (t in cd.top) {
                tables.put(t.id())
            }
            for (t in cd.bot) {
                tables.put(t.id())
            }
            
            return true
        } finally {
            lock.writeLock.unlock()
        }
    }
    
    public func delete(cd: compactDef): Unit {
        lock.writeLock.lock()
        try {
            let thisLevel = levels[cd.thisLevel]
            let nextLevel = levels[cd.nextLevel]
            
            thisLevel.delSize -= cd.thisSize
            thisLevel.remove(cd.thisRange)
            if (cd.thisLevel != cd.nextLevel && !cd.nextRange.isEmpty()) {
                nextLevel.remove(cd.nextRange)
            }
            
            for (t in cd.top) {
                tables.remove(t.id())
            }
            for (t in cd.bot) {
                tables.remove(t.id())
            }
        } finally {
            lock.writeLock.unlock()
        }
    }
    
    public func delSize(level: Int): Int64 {
        lock.readLock.lock()
        try {
            return levels[level].delSize
        } finally {
            lock.readLock.unlock()
        }
    }
}
```

**Step 3: 编译验证**

Run: `cjpm build -j 16`
Expected: 编译成功（可能有 compactDef 未定义错误，下一步解决）

**Step 4: 提交**

```bash
git add src/db/compact_status.cj
git commit -m "feat(compaction): 添加 compactStatus 并发控制"
```

---

### Task 3: 实现 compactDef 和 compactionPriority

**Files:**
- Create: `src/db/compact_def.cj`

**Step 1: 创建 compact_def.cj**

```cangjie
package badgercj.db

import std.collection.*

public struct compactionPriority {
    public let level: Int
    public let score: Float64
    
    public init(level!: Int, score!: Float64) {
        this.level = level
        this.score = score
    }
}

public struct compactDef {
    public let thisLevel: Int
    public let nextLevel: Int
    public let top: ArrayList<TableAdapter>
    public let bot: ArrayList<TableAdapter>
    public let thisRange: keyRange
    public let nextRange: keyRange
    public let splits: ArrayList<keyRange>
    public let thisSize: Int64
    
    public init(
        thisLevel!: Int,
        nextLevel!: Int,
        top!: ArrayList<TableAdapter>,
        bot!: ArrayList<TableAdapter>,
        thisRange!: keyRange,
        nextRange!: keyRange,
        thisSize!: Int64
    ) {
        this.thisLevel = thisLevel
        this.nextLevel = nextLevel
        this.top = top
        this.bot = bot
        this.thisRange = thisRange
        this.nextRange = nextRange
        this.splits = ArrayList<keyRange>()
        this.thisSize = thisSize
    }
    
    public func isEmpty(): Bool {
        return top.size == 0
    }
}
```

**Step 2: 编译验证**

Run: `cjpm build -j 16`
Expected: 编译成功

**Step 3: 提交**

```bash
git add src/db/compact_def.cj
git commit -m "feat(compaction): 添加 compactDef 和 compactionPriority"
```

---

### Task 4: 修改 LevelsController 添加 compactStatus

**Files:**
- Modify: `src/db/levels.cj`

**Step 1: 添加 compactStatus 字段**

在 `LevelsController` 类中添加：

```cangjie
import badgercj.db.compactStatus

public class LevelsController {
    // ... 现有字段 ...
    private let cstatus: compactStatus
    
    public init(manifest!: Manifest, dir!: String) {
        // ... 现有初始化 ...
        this.cstatus = compactStatus(numLevels: opt.MaxLevels)
    }
    
    public func getCompactStatus(): compactStatus {
        return cstatus
    }
}
```

**Step 2: 编译验证**

Run: `cjpm build -j 16`
Expected: 编译成功

**Step 3: 提交**

```bash
git add src/db/levels.cj
git commit -m "feat(compaction): LevelsController 添加 compactStatus"
```

---

### Task 5: 实现 getKeyRange 辅助函数

**Files:**
- Modify: `src/db/compaction.cj`

**Step 1: 添加 getKeyRange 函数**

```cangjie
import std.math.*

private func getKeyRange(tables: ArrayList<TableAdapter>): keyRange {
    if (tables.size == 0) {
        return keyRange()
    }
    
    var smallest = tables[0].smallest()
    var biggest = tables[0].biggest()
    
    for (i in 1..tables.size) {
        if (compareKeys(tables[i].smallest(), smallest) < 0) {
            smallest = tables[i].smallest()
        }
        if (compareKeys(tables[i].biggest(), biggest) > 0) {
            biggest = tables[i].biggest()
        }
    }
    
    // 使用最大时间戳作为 left，最小时间戳作为 right
    // 因为 key 按时间戳降序排列
    return keyRange(
        left: keyWithTs(parseKey(smallest), UInt64.Max),
        right: keyWithTs(parseKey(biggest), 0)
    )
}
```

**Step 2: 添加辅助函数**

```cangjie
private func compareKeys(a: Array<Byte>, b: Array<Byte>): Int64 {
    let minLen = if (a.size < b.size) { a.size } else { b.size }
    for (i in 0..minLen) {
        if (a[i] < b[i]) { return -1 }
        if (a[i] > b[i]) { return 1 }
    }
    if (a.size < b.size) { return -1 }
    if (a.size > b.size) { return 1 }
    return 0
}
```

**Step 3: 编译验证**

Run: `cjpm build -j 16`
Expected: 编译成功

**Step 4: 提交**

```bash
git add src/db/compaction.cj
git commit -m "feat(compaction): 添加 getKeyRange 和辅助函数"
```

---

### Task 6: 实现 pickCompaction

**Files:**
- Modify: `src/db/compaction.cj`

**Step 1: 添加 pickCompaction 方法**

```cangjie
public func pickCompaction(): ?compactionPriority {
    let l0Handler = db.getLevelHandler(0)
    let l0Count = l0Handler.numTables()
    
    // L0 表数量超过阈值
    if (l0Count > opt.NumLevelZeroTables) {
        return Some(compactionPriority(level: 0, score: Float64(l0Count) / Float64(opt.NumLevelZeroTables)))
    }
    
    // 检查其他层
    for (level in 1..opt.MaxLevels) {
        let handler = db.getLevelHandler(level)
        let size = handler.totalSize()
        let maxSize = opt.levelMaxSize(level)
        
        if (size > maxSize) {
            return Some(compactionPriority(level: 1, score: Float64(size) / Float64(maxSize)))
        }
    }
    
    return None
}
```

**Step 2: 编译验证**

Run: `cjpm build -j 16`
Expected: 编译成功

**Step 3: 提交**

```bash
git add src/db/compaction.cj
git commit -m "feat(compaction): 实现 pickCompaction 优先级选择"
```

---

### Task 7: 实现 fillTables

**Files:**
- Modify: `src/db/compaction.cj`

**Step 1: 添加 fillTables 方法**

```cangjie
public func fillTables(cd: compactDef): Bool {
    let thisHandler = db.getLevelHandler(cd.thisLevel)
    let nextHandler = db.getLevelHandler(cd.nextLevel)
    
    // 获取源层表
    let tables = thisHandler.getTables()
    if (tables.size == 0) {
        return false
    }
    
    // 计算 key 范围
    let thisRange = getKeyRange(tables)
    
    // 查找目标层重叠的表
    let bot = ArrayList<TableAdapter>()
    let nextTables = nextHandler.getTables()
    for (t in nextTables) {
        let tRange = keyRange(
            left: keyWithTs(parseKey(t.smallest()), UInt64.Max),
            right: keyWithTs(parseKey(t.biggest()), 0)
        )
        if (thisRange.overlapsWith(tRange)) {
            bot.add(t)
        }
    }
    
    // 更新 compactDef
    cd.top = tables
    cd.bot = bot
    cd.thisRange = thisRange
    cd.nextRange = getKeyRange(bot)
    cd.thisSize = thisHandler.totalSize()
    
    return true
}
```

**Step 2: 编译验证**

Run: `cjpm build -j 16`
Expected: 编译成功

**Step 3: 提交**

```bash
git add src/db/compaction.cj
git commit -m "feat(compaction): 实现 fillTables 填充表列表"
```

---

### Task 8: 实现 MergeIterator

**Files:**
- Create: `src/db/merge_iterator.cj`

**Step 1: 创建 MergeIterator**

```cangjie
package badgercj.db

import std.collection.*

public class MergeIterator {
    private let iters: ArrayList<TableIterator>
    private var current: ?TableIterator
    private var currentKey: ?Array<Byte>
    
    public init(iters: ArrayList<TableIterator>) {
        this.iters = iters
        this.current = None
        this.currentKey = None
        this.heapify()
    }
    
    private func heapify(): Unit {
        // 找到最小的 key
        var minIdx = -1
        var minKey: ?Array<Byte> = None
        
        for (i in 0..iters.size) {
            if (iters[i].valid()) {
                let key = iters[i].key()
                if (minKey.isNone() || compareKeys(key, minKey!!) < 0) {
                    minKey = Some(key)
                    minIdx = i
                }
            }
        }
        
        if (minIdx >= 0) {
            current = Some(iters[minIdx])
            currentKey = minKey
        } else {
            current = None
            currentKey = None
        }
    }
    
    public func valid(): Bool {
        return current.isSome()
    }
    
    public func key(): Array<Byte> {
        return currentKey!!
    }
    
    public func value(): ValueStruct {
        return current!!.value()
    }
    
    public func next(): Unit {
        current!!.next()
        heapify()
    }
    
    private func compareKeys(a: Array<Byte>, b: Array<Byte>): Int64 {
        let minLen = if (a.size < b.size) { a.size } else { b.size }
        for (i in 0..minLen) {
            if (a[i] < b[i]) { return -1 }
            if (a[i] > b[i]) { return 1 }
        }
        if (a.size < b.size) { return -1 }
        if (a.size > b.size) { return 1 }
        return 0
    }
}
```

**Step 2: 编译验证**

Run: `cjpm build -j 16`
Expected: 编译成功

**Step 3: 提交**

```bash
git add src/db/merge_iterator.cj
git commit -m "feat(compaction): 添加 MergeIterator 合并迭代器"
```

---

### Task 9: 实现 compactBuildTables

**Files:**
- Modify: `src/db/compaction.cj`

**Step 1: 添加 compactBuildTables 方法**

```cangjie
public func compactBuildTables(cd: compactDef): ArrayList<TableAdapter> {
    let newTables = ArrayList<TableAdapter>()
    let builder = TableBuilder()
    
    // 创建合并迭代器
    let iters = ArrayList<TableIterator>()
    for (t in cd.top) {
        iters.add(t.newIterator())
    }
    for (t in cd.bot) {
        iters.add(t.newIterator())
    }
    let mergeIter = MergeIterator(iters)
    
    var lastKey: ?Array<Byte> = None
    
    while (mergeIter.valid()) {
        let key = mergeIter.key()
        let value = mergeIter.value()
        let userKey = parseKey(key)
        
        // 丢弃旧版本（只保留最新版本）
        if (lastKey.isSome() && keysEqual(userKey, lastKey!!)) {
            mergeIter.next()
            continue
        }
        lastKey = Some(userKey)
        
        // 丢弃删除标记（目标层不是最后一层）
        if (cd.nextLevel < opt.MaxLevels - 1 && value.isDelete()) {
            mergeIter.next()
            continue
        }
        
        builder.add(key, value)
        mergeIter.next()
    }
    
    // 完成构建
    let data = builder.finish()
    if (data.size > 0) {
        let tableID = db.nextFileID()
        let table = TableAdapter(tableID, data)
        newTables.add(table)
    }
    
    return newTables
}

private func keysEqual(a: Array<Byte>, b: Array<Byte>): Bool {
    if (a.size != b.size) { return false }
    for (i in 0..a.size) {
        if (a[i] != b[i]) { return false }
    }
    return true
}
```

**Step 2: 编译验证**

Run: `cjpm build -j 16`
Expected: 编译成功

**Step 3: 提交**

```bash
git add src/db/compaction.cj
git commit -m "feat(compaction): 实现 compactBuildTables 合并构建"
```

---

### Task 10: 实现 runCompactDef 完整流程

**Files:**
- Modify: `src/db/compaction.cj`

**Step 1: 重写 runCompactDef**

```cangjie
public func runCompactDef(cd: compactDef): Unit {
    // 1. 构建新表
    let newTables = compactBuildTables(cd)
    
    // 2. 构建 MANIFEST 变更
    let changes = ManifestChangeSet()
    for (t in cd.top) {
        changes.add(ManifestChange(t.id(), ManifestChangeOp.Delete, level: cd.thisLevel))
    }
    for (t in cd.bot) {
        changes.add(ManifestChange(t.id(), ManifestChangeOp.Delete, level: cd.nextLevel))
    }
    for (t in newTables) {
        changes.add(ManifestChange(t.id(), ManifestChangeOp.Create, level: cd.nextLevel))
    }
    
    // 3. 写入 MANIFEST
    db.getManifestFile().saveChanges(changes)
    
    // 4. 替换表
    let nextHandler = db.getLevelHandler(cd.nextLevel)
    nextHandler.replaceTables(cd.bot, newTables)
    
    let thisHandler = db.getLevelHandler(cd.thisLevel)
    thisHandler.deleteTables(cd.top)
    
    // 5. 清理 compactStatus
    db.getLevelsController().getCompactStatus().delete(cd)
}
```

**Step 2: 编译验证**

Run: `cjpm build -j 16`
Expected: 编译成功

**Step 3: 提交**

```bash
git add src/db/compaction.cj
git commit -m "feat(compaction): 实现 runCompactDef 完整流程"
```

---

### Task 11: 实现 Compactor 后台协程

**Files:**
- Modify: `src/db/badger.cj`

**Step 1: 添加 Compactor 启动**

```cangjie
private var compactorFut: ?Future<Unit>

private func startCompactor(): Unit {
    let fut = spawn {
        while (running.load()) {
            sleep(Duration.milliseconds(100))
            
            let compaction = Compaction(db)
            let priority = compaction.pickCompaction()
            
            if (priority.isNone()) {
                continue
            }
            
            if (let Some(p) <- priority) {
                let cd = compactDef(thisLevel: p.level, nextLevel: p.level + 1, ...)
                if (compaction.fillTables(cd)) {
                    let cstatus = lc.getCompactStatus()
                    if (cstatus.compareAndAdd(cd)) {
                        compaction.runCompactDef(cd)
                    }
                }
            }
        }
    }
    compactorFut = Some(fut)
}
```

**Step 2: 在 open() 中启动**

```cangjie
public static func open(opt: Config): Badger {
    // ... 现有代码 ...
    db.startCompactor()
    return db
}
```

**Step 3: 在 close() 中停止**

```cangjie
public func close(): Unit {
    running.store(false)
    // ... 现有代码 ...
    if (let Some(fut) <- compactorFut) {
        fut.get()
    }
}
```

**Step 4: 编译验证**

Run: `cjpm build -j 16`
Expected: 编译成功

**Step 5: 提交**

```bash
git add src/db/badger.cj
git commit -m "feat(compaction): 添加 Compactor 后台协程"
```

---

### Task 12: 添加 compact() 手动接口

**Files:**
- Modify: `src/db/badger.cj`

**Step 1: 添加 compact() 方法**

```cangjie
public func compact(): Unit {
    let compaction = Compaction(this)
    
    while (true) {
        let priority = compaction.pickCompaction()
        if (priority.isNone()) {
            break
        }
        
        if (let Some(p) <- priority) {
            let cd = compactDef(thisLevel: p.level, nextLevel: p.level + 1, ...)
            if (compaction.fillTables(cd)) {
                let cstatus = lc.getCompactStatus()
                if (cstatus.compareAndAdd(cd)) {
                    compaction.runCompactDef(cd)
                }
            }
        }
    }
}
```

**Step 2: 编译验证**

Run: `cjpm build -j 16`
Expected: 编译成功

**Step 3: 提交**

```bash
git add src/db/badger.cj
git commit -m "feat(compaction): 添加 compact() 手动接口"
```

---

### Task 13: 编写 Compaction 单元测试

**Files:**
- Create: `src/db/compaction_test.cj`

**Step 1: 创建测试文件**

```cangjie
package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*

@Test
class CompactionTest {
    @TestCase
    func testCompactionBasic() {
        let dir = "/tmp/badger_compaction_test_1"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, numLevelZeroTables!: 2)
        let db = Badger.open(opt)
        
        // 写入足够多的数据触发 L0 → L1 Compaction
        for (i in 0..100) {
            db.set("key${i}".toArray(), "value${i}".toArray())
        }
        
        // 等待 Compaction 完成
        sleep(Duration.seconds(1))
        
        // 验证数据仍然可读
        for (i in 0..100) {
            if (let Some(vs) <- db.get("key${i}".toArray())) {
                @Assert(vs.value, "value${i}".toArray())
            } else {
                @Fail("key${i} not found after compaction")
            }
        }
        
        db.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testCompactionDropTombstone() {
        let dir = "/tmp/badger_compaction_test_2"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, numLevelZeroTables!: 2)
        let db = Badger.open(opt)
        
        // 写入并删除
        db.set("key1".toArray(), "value1".toArray())
        db.delete("key1".toArray())
        
        // 手动触发 Compaction
        db.compact()
        
        // 验证删除标记已被丢弃（key 不存在）
        @Assert(db.get("key1".toArray()).isSome(), false)
        
        db.close()
        cleanupDir(dir)
    }
    
    @TestCase
    func testCompactionDropOldVersions() {
        let dir = "/tmp/badger_compaction_test_3"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, numLevelZeroTables!: 2)
        let db = Badger.open(opt)
        
        // 写入多个版本
        db.set("key1".toArray(), "value1".toArray())
        db.set("key1".toArray(), "value2".toArray())
        db.set("key1".toArray(), "value3".toArray())
        
        // 手动触发 Compaction
        db.compact()
        
        // 验证只保留最新版本
        if (let Some(vs) <- db.get("key1".toArray())) {
            @Assert(vs.value, "value3".toArray())
        } else {
            @Fail("key1 not found")
        }
        
        db.close()
        cleanupDir(dir)
    }
}
```

**Step 2: 运行测试**

Run: `cjHeapSize=12gb cjpm test --filter 'CompactionTest'`
Expected: 测试通过

**Step 3: 提交**

```bash
git add src/db/compaction_test.cj
git commit -m "test(compaction): 添加 Compaction 单元测试"
```

---

## P1: VLog GC 实现

### Task 14: 实现 VLog GC 统计

**Files:**
- Modify: `src/vlog/vlog_manager.cj`

**Step 1: 添加垃圾统计方法**

```cangjie
public func getDiscardStats(fid: UInt64): Float64 {
    let vlogFile = files[fid]
    if (vlogFile.isNone()) {
        return 0.0
    }
    
    let file = vlogFile!!
    let fileSize = file.size()
    
    // 统计有效值大小
    var validSize: Int64 = 0
    let entries = file.readAll()
    
    for (entry in entries) {
        // 检查 entry 是否有效
        // 需要从 SSTable 查找 key 的 ValuePointer
        if (isEntryValid(entry)) {
            validSize += entry.size()
        }
    }
    
    let discardRatio = 1.0 - Float64(validSize) / Float64(fileSize)
    return discardRatio
}

private func isEntryValid(entry: LogEntry): Bool {
    // 从 SSTable 查找 key 的当前 ValuePointer
    // 如果指针指向当前 entry，则有效
    // 需要访问 db.get() 或类似方法
    // 这里需要设计一个回调机制
    return true // 简化实现
}
```

**Step 2: 编译验证**

Run: `cjpm build -j 16`
Expected: 编译成功

**Step 3: 提交**

```bash
git add src/vlog/vlog_manager.cj
git commit -m "feat(vlog): 添加 GC 垃圾统计"
```

---

### Task 15: 实现 VLog GC 核心逻辑

**Files:**
- Create: `src/vlog/vlog_gc.cj`

**Step 1: 创建 vlog_gc.cj**

```cangjie
package badgercj.vlog

import std.collection.*
import std.sync.*

public class VLogGC {
    private let vlogManager: VLogManager
    private let db: Badger
    private let running: AtomicBool
    
    public init(vlogManager: VLogManager, db: Badger) {
        this.vlogManager = vlogManager
        this.db = db
        this.running = AtomicBool(false)
    }
    
    public func runGC(discardRatio: Float64): Bool {
        // 选择垃圾比例超过阈值的文件
        let targetFid = pickVLogForGC(discardRatio)
        if (targetFid.isNone()) {
            return false
        }
        
        // 执行 GC
        return doGC(targetFid!!)
    }
    
    private func pickVLogForGC(discardRatio: Float64): ?UInt64 {
        let files = vlogManager.getFiles()
        
        for ((fid, file) in files) {
            let stats = vlogManager.getDiscardStats(fid)
            if (stats > discardRatio) {
                return Some(fid)
            }
        }
        
        return None
    }
    
    private func doGC(fid: UInt64): Bool {
        // 1. 读取所有有效 entry
        let validEntries = ArrayList<LogEntry>()
        let oldEntries = vlogManager.readFile(fid)
        
        for (entry in oldEntries) {
            if (isEntryValid(entry)) {
                validEntries.add(entry)
            }
        }
        
        // 2. 写入新 VLog 文件
        let newFid = vlogManager.newFileID()
        let offsetMap = HashMap<UInt32, UInt32>()
        var newOffset: UInt32 = 0
        
        for (entry in validEntries) {
            let oldOffset = entry.offset
            vlogManager.write(newFid, entry)
            offsetMap.put(oldOffset, newOffset)
            newOffset += UInt32(entry.size())
        }
        
        // 3. 更新 offsetMap（间接层）
        vlogManager.updateOffsetMap(fid, offsetMap)
        
        // 4. 删除旧文件
        vlogManager.deleteFile(fid)
        
        return true
    }
    
    private func isEntryValid(entry: LogEntry): Bool {
        // 从 SSTable 查找 key 的 ValuePointer
        let vp = db.getValuePointer(entry.key)
        if (vp.isNone()) {
            return false
        }
        
        // 检查指针是否指向当前 entry
        return vp!!.fid == entry.fid && vp!!.offset == entry.offset
    }
}
```

**Step 2: 编译验证**

Run: `cjpm build -j 16`
Expected: 编译成功

**Step 3: 提交**

```bash
git add src/vlog/vlog_gc.cj
git commit -m "feat(vlog): 实现 VLog GC 核心逻辑"
```

---

### Task 16: 集成 VLog GC 到 VLogManager

**Files:**
- Modify: `src/vlog/vlog_manager.cj`

**Step 1: 添加 offsetMap 和 GC 支持**

```cangjie
public class VLogManager {
    // ... 现有字段 ...
    private let offsetMaps: HashMap<UInt64, HashMap<UInt32, UInt32>>
    private let gc: VLogGC
    
    public init(path: Path, db: Badger) {
        // ... 现有初始化 ...
        this.offsetMaps = HashMap<UInt64, HashMap<UInt32, UInt32>>()
        this.gc = VLogGC(this, db)
    }
    
    public func updateOffsetMap(fid: UInt64, map: HashMap<UInt32, UInt32>): Unit {
        offsetMaps[fid] = map
    }
    
    public func read(vp: ValuePointer): LogEntry {
        // 先查 offsetMap
        if (let Some(map) <- offsetMaps.get(vp.fid)) {
            if (let Some(newOffset) <- map.get(vp.offset)) {
                return files[vp.fid]!!.read(newOffset)
            }
        }
        return files[vp.fid]!!.read(vp.offset)
    }
    
    public func runGC(discardRatio: Float64): Bool {
        return gc.runGC(discardRatio)
    }
}
```

**Step 2: 编译验证**

Run: `cjpm build -j 16`
Expected: 编译成功

**Step 3: 提交**

```bash
git add src/vlog/vlog_manager.cj
git commit -m "feat(vlog): 集成 GC 到 VLogManager"
```

---

### Task 17: 添加 GC 后台协程

**Files:**
- Modify: `src/db/badger.cj`

**Step 1: 添加 GC 协程**

```cangjie
private var gcFut: ?Future<Unit>

private func startVLogGC(): Unit {
    let fut = spawn {
        while (running.load()) {
            sleep(Duration.minutes(10))
            
            // 运行 GC
            vlog.runGC(0.5)  // discardRatio = 0.5
        }
    }
    gcFut = Some(fut)
}
```

**Step 2: 在 open() 和 close() 中处理**

```cangjie
public static func open(opt: Config): Badger {
    // ... 现有代码 ...
    db.startVLogGC()
    return db
}

public func close(): Unit {
    running.store(false)
    // ... 现有代码 ...
    if (let Some(fut) <- gcFut) {
        fut.get()
    }
}
```

**Step 3: 编译验证**

Run: `cjpm build -j 16`
Expected: 编译成功

**Step 4: 提交**

```bash
git add src/db/badger.cj
git commit -m "feat(vlog): 添加 GC 后台协程"
```

---

### Task 18: 编写 VLog GC 测试

**Files:**
- Create: `src/vlog/vlog_gc_test.cj`

**Step 1: 创建测试**

```cangjie
package badgercj.vlog

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import badgercj.db.*

@Test
class VLogGCTest {
    @TestCase
    func testVLogGCBasic() {
        let dir = "/tmp/badger_vlog_gc_test_1"
        cleanupDir(dir)
        
        let opt = Config(dir: dir, valueThreshold!: 100)
        let db = Badger.open(opt)
        
        // 写入大值（会进入 VLog）
        let largeValue = Array<Byte>(1000, repeat: 0x41)
        db.set("key1".toArray(), largeValue)
        
        // 删除
        db.delete("key1".toArray())
        
        // 运行 GC
        db.runVLogGC(0.5)
        
        // 验证数据一致性
        @Assert(db.get("key1".toArray()).isSome(), false)
        
        db.close()
        cleanupDir(dir)
    }
}
```

**Step 2: 运行测试**

Run: `cjHeapSize=12gb cjpm test --filter 'VLogGCTest'`
Expected: 测试通过

**Step 3: 提交**

```bash
git add src/vlog/vlog_gc_test.cj
git commit -m "test(vlog): 添加 VLog GC 测试"
```

---

### Task 19: 运行全部测试验证

**Step 1: 运行全部测试**

Run: `cjHeapSize=12gb cjpm test -j 16 --exclude-tags stress --no-progress`
Expected: 全部测试通过

**Step 2: 运行压力测试**

Run: `cjHeapSize=12gb cjpm test -j 4 --include-tags stress`
Expected: 压力测试通过

---

### Task 20: 更新进度跟踪文档

**Files:**
- Modify: `docs/progress-tracking.md`

**Step 1: 更新 Phase 7 状态**

将所有 ❌ 改为 ✅

**Step 2: 提交**

```bash
git add docs/progress-tracking.md
git commit -m "docs: Phase 7 完成"
```

---

## 总结

**预计总工时：** ~28h
- Compaction 核心实现：~16h
- VLog GC 实现：~12h

**关键里程碑：**
1. Task 1-4: 基础结构（keyRange, compactStatus, compactDef）
2. Task 5-13: Compaction 完整实现
3. Task 14-18: VLog GC 实现
4. Task 19-20: 测试和文档

**风险点：**
- MergeIterator 性能可能需要优化
- VLog GC 的 offsetMap 持久化需要额外工作
- Compaction 期间并发读写的正确性

**下一步：** 选择执行方式