# 迭代器架构重构实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 重构迭代器架构，解决重新打开后迭代器遍历不到数据的问题，支持正向/反向迭代。

**Architecture:** 创建公开的 TableIter 接口，TableIterator 实现该接口，通过 TableIterWrapper 包装为 SimpleIterator。

**Tech Stack:** 仓颉语言，protected/public 访问控制

---

## Task 1: 创建 TableIter 公开接口

**Files:**
- Create: `src/table/table_iter.cj`

**Step 1: 创建 TableIter 接口**

```cangjie
package badgercj.table

import std.collection.*

/**
 * TableIter - 公开的表迭代器接口
 * 
 * 支持正向和反向迭代
 */
public interface TableIter {
    func seekFirst(): Unit
    func seekLast(): Unit
    func seek(key: Array<Byte>): Unit
    func next(): Unit
    func prev(): Unit
    func isValid(): Bool
    func key(): Array<Byte>
    func value(): Array<Byte>
    func valueStruct(): ?ValueStruct
}
```

**Step 2: 编译验证**

Run: `cjpm build -j 16`
Expected: 成功

**Step 3: 提交**

```bash
git add src/table/table_iter.cj
git commit -m "feat: 添加 TableIter 公开接口"
```

---

## Task 2: BlockIterator 添加 prev() 和 seekLast()

**Files:**
- Modify: `src/table/block_iterator.cj`
- Test: `src/table/block_iterator_test.cj`

**Step 1: 写失败测试 - testPrev**

```cangjie
@Test
class BlockIteratorTest {
    // ... 现有测试 ...

    @TestCase
    func testPrev(): Unit {
        let builder = BlockBuilder(blockSize: 1024)
        builder.add("key1".toArray(), ValueStruct("value1".toArray()))
        builder.add("key2".toArray(), ValueStruct("value2".toArray()))
        builder.add("key3".toArray(), ValueStruct("value3".toArray()))
        
        let data = builder.finish()
        let iter = BlockIterator(data, "key1".toArray())
        
        iter.seekToLast()
        @Assert(iter.isValid())
        @Assert(iter.key(), "key3".toArray())
        
        iter.prev()
        @Assert(iter.isValid())
        @Assert(iter.key(), "key2".toArray())
        
        iter.prev()
        @Assert(iter.isValid())
        @Assert(iter.key(), "key1".toArray())
        
        iter.prev()
        @Assert(!iter.isValid())
    }
}
```

**Step 2: 运行测试验证失败**

Run: `cjpm test --filter 'BlockIteratorTest.testPrev'`
Expected: FAIL - prev() not implemented

**Step 3: 实现 prev() 和 seekLast()**

在 BlockIterator 类中添加：

```cangjie
public func seekToLast(): Unit {
    if (offsets.size == 0) {
        valid_ = false
        return
    }
    currentIdx = offsets.size - 1
    updateCurrent()
}

public func prev(): Unit {
    if (!valid_) {
        return
    }
    if (currentIdx > 0) {
        currentIdx--
        updateCurrent()
    } else {
        valid_ = false
    }
}
```

**Step 4: 运行测试验证通过**

Run: `cjpm test --filter 'BlockIteratorTest.testPrev'`
Expected: PASS

**Step 5: 提交**

```bash
git add src/table/block_iterator.cj src/table/block_iterator_test.cj
git commit -m "feat: BlockIterator 添加 prev() 和 seekLast() 支持"
```

---

## Task 3: TableIterator 实现 TableIter 接口

**Files:**
- Modify: `src/table/table_iterator.cj`

**Step 1: 修改 TableIterator 实现 TableIter**

```cangjie
package badgercj.table

import std.collection.*

/**
 * TableIterator - Table 迭代器
 */
protected class TableIterator <: TableIter {
    private let table: Table
    private var blockIdx: Int64
    private var blockIter: BlockIterator
    
    public init(table: Table) {
        this.table = table
        this.blockIdx = 0
        this.blockIter = BlockIterator([], [])
        seekFirst()
    }
    
    public func seekFirst(): Unit {
        blockIdx = 0
        if (table.numBlocks() > 0) {
            blockIter = table.blockIterator(0)
            blockIter.seekToFirst()
        }
    }
    
    public func seekLast(): Unit {
        blockIdx = table.numBlocks() - 1
        if (blockIdx >= 0) {
            blockIter = table.blockIterator(blockIdx)
            blockIter.seekToLast()
        }
    }
    
    public func seek(key: Array<Byte>): Unit {
        blockIdx = table.findBlock(key)
        if (blockIdx >= 0 && blockIdx < table.numBlocks()) {
            blockIter = table.blockIterator(blockIdx)
            blockIter.seek(key)
        }
    }
    
    public func next(): Unit {
        blockIter.next()
        if (!blockIter.isValid()) {
            blockIdx++
            if (blockIdx < table.numBlocks()) {
                blockIter = table.blockIterator(blockIdx)
                blockIter.seekToFirst()
            }
        }
    }
    
    public func prev(): Unit {
        blockIter.prev()
        if (!blockIter.isValid() && blockIdx > 0) {
            blockIdx--
            blockIter = table.blockIterator(blockIdx)
            blockIter.seekToLast()
        }
    }
    
    public func isValid(): Bool {
        blockIdx < table.numBlocks() && blockIter.isValid()
    }
    
    public func key(): Array<Byte> {
        blockIter.key()
    }
    
    public func value(): Array<Byte> {
        blockIter.value()
    }
    
    public func valueStruct(): ?ValueStruct {
        blockIter.valueStruct()
    }
}
```

**Step 2: 编译验证**

Run: `cjpm build -j 16`
Expected: 成功

**Step 3: 提交**

```bash
git add src/table/table_iterator.cj
git commit -m "feat: TableIterator 实现 TableIter 接口，支持 prev()"
```

---

## Task 4: TableInterface 添加 newIterator() 方法

**Files:**
- Modify: `src/db/table_interface.cj`
- Modify: `src/db/table_adapter.cj`
- Modify: `src/db/mock_table.cj`

**Step 1: 修改 TableInterface 接口**

```cangjie
package badgercj.db

import std.collection.*
import badgercj.table.*

public interface TableInterface {
    func getId(): UInt64
    func smallest(): Array<Byte>
    func biggest(): Array<Byte>
    func get(key: Array<Byte>, readTs: UInt64): Option<ValueStruct>
    func size(): Int64
    func getMaxVersion(): UInt64
    func keyCount(): UInt32
    func uncompressedSize(): Int64
    func offsetsLength(): Int64
    func getOffsetKey(idx: Int64): Array<Byte>
    func keySplits(n: Int64, prefix: Array<Byte>): ArrayList<Array<Byte>>
    func newIterator(): TableIter
}
```

**Step 2: 修改 TableAdapter**

```cangjie
// 在 TableAdapter 类中添加
public func newIterator(): TableIter {
    table.newIterator()
}
```

**Step 3: 创建 MockTableIter**

在 mock_table.cj 中添加：

```cangjie
public func newIterator(): TableIter {
    MockTableIter(entries)
}

protected class MockTableIter <: TableIter {
    private let entries: ArrayList<(Array<Byte>, ValueStruct)>
    private var idx: Int64
    
    public init(entries: ArrayList<(Array<Byte>, ValueStruct)>) {
        this.entries = entries
        this.idx = 0
    }
    
    public func seekFirst(): Unit { idx = 0 }
    public func seekLast(): Unit { idx = entries.size - 1 }
    public func seek(_: Array<Byte>): Unit { idx = 0 }
    public func next(): Unit { idx++ }
    public func prev(): Unit { if (idx > 0) { idx-- } }
    public func isValid(): Bool { idx >= 0 && idx < entries.size }
    public func key(): Array<Byte> { entries[idx][0] }
    public func value(): Array<Byte> { entries[idx][1].value }
    public func valueStruct(): ?ValueStruct { Some(entries[idx][1]) }
}
```

**Step 4: 编译验证**

Run: `cjpm build -j 16`
Expected: 成功

**Step 5: 提交**

```bash
git add src/db/table_interface.cj src/db/table_adapter.cj src/db/mock_table.cj
git commit -m "feat: TableInterface 添加 newIterator()，实现 TableIter"
```

---

## Task 5: 创建 TableIterWrapper

**Files:**
- Create: `src/db/table_iter_wrapper.cj`
- Delete: `src/db/table_interface_iterator.cj`

**Step 1: 创建 TableIterWrapper**

```cangjie
package badgercj.db

import badgercj.table.*

/**
 * TableIterWrapper - 将 TableIter 包装为 SimpleIterator
 * 
 * 支持正向和反向迭代
 */
public class TableIterWrapper <: SimpleIterator {
    private let iter: TableIter
    private let reverse: Bool
    
    public init(iter: TableIter, reverse!: Bool = false) {
        super()
        this.iter = iter
        this.reverse = reverse
        rewind()
    }
    
    public override func valid(): Bool { iter.isValid() }
    public override func key(): Array<Byte> { iter.key() }
    public override func value(): Array<Byte> { iter.value() }
    
    public override func next(): Unit {
        if (reverse) { iter.prev() } else { iter.next() }
    }
    
    public override func rewind(): Unit {
        if (reverse) { iter.seekLast() } else { iter.seekFirst() }
    }
    
    public override func seek(key: Array<Byte>): Unit {
        iter.seek(key)
    }
}
```

**Step 2: 删除旧文件**

```bash
rm src/db/table_interface_iterator.cj
```

**Step 3: 编译验证**

Run: `cjpm build -j 16`
Expected: 成功

**Step 4: 提交**

```bash
git add src/db/table_iter_wrapper.cj
git rm src/db/table_interface_iterator.cj
git commit -m "feat: 创建 TableIterWrapper，删除旧的 TableInterfaceIterator"
```

---

## Task 6: 更新 LevelHandler 使用新包装器

**Files:**
- Modify: `src/db/level_handler.cj`

**Step 1: 修改 appendIterators 方法**

```cangjie
public func appendIterators(iters: ArrayList<SimpleIterator>, opt: IteratorOptions): Unit {
    synchronized(lock) {
        for (table in tables) {
            let iter = table.newIterator()
            iters.add(TableIterWrapper(iter, reverse: opt.reverse))
        }
    }
}
```

**Step 2: 编译验证**

Run: `cjpm build -j 16`
Expected: 成功

**Step 3: 提交**

```bash
git add src/db/level_handler.cj
git commit -m "feat: LevelHandler 使用 TableIterWrapper 支持反向迭代"
```

---

## Task 7: 更新 MemTableIterator 实现 TableIter

**Files:**
- Modify: `src/db/memtable_iterator.cj`

**Step 1: 修改 MemTableIterator**

确保 MemTableIterator 实现完整的迭代器接口，支持反向迭代。

**Step 2: 编译验证**

Run: `cjpm build -j 16`
Expected: 成功

**Step 3: 提交**

```bash
git add src/db/memtable_iterator.cj
git commit -m "feat: MemTableIterator 支持 TableIter 接口"
```

---

## Task 8: 删除冗余的 MockTableIterator

**Files:**
- Delete: `src/db/mock_table_iterator.cj`

**Step 1: 删除文件**

```bash
rm src/db/mock_table_iterator.cj
```

**Step 2: 编译验证**

Run: `cjpm build -j 16`
Expected: 成功

**Step 3: 提交**

```bash
git rm src/db/mock_table_iterator.cj
git commit -m "refactor: 删除冗余的 MockTableIterator"
```

---

## Task 9: 运行全量测试验证

**Files:**
- None

**Step 1: 运行全量测试**

Run: `cjpm test -j 16 --no-progress`
Expected: 全部通过

**Step 2: 运行特定测试**

Run: `cjpm test --filter 'PersistenceTest.testIteratorAfterReopen'`
Expected: PASS

**Step 3: 如有失败，修复问题**

如果测试失败，分析错误并修复。

---

## Task 10: 更新 README 和库级记忆

**Files:**
- Modify: `README.md`

**Step 1: 更新 README**

在已实现功能中添加迭代器改进说明。

**Step 2: 更新库级记忆**

记录迭代器架构变更。

**Step 3: 提交**

```bash
git add README.md
git commit -m "docs: 更新 README 迭代器改进说明"
```

---

## 验证清单

- [ ] `testIteratorAfterReopen` 测试通过
- [ ] 正向迭代正常工作
- [ ] 反向迭代正常工作
- [ ] 全量测试通过（282+ 测试）
- [ ] 编译无警告