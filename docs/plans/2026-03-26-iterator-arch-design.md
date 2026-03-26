# 迭代器架构重构设计

## 背景

### 问题

数据库重新打开后，iterator 遍历不到已持久化的数据：
- `get()` 能找到数据
- `iterator` 遍历返回 0 条记录

### 根因

1. **可见性问题**：`Table` 和 `TableIterator` 都是 `protected class`，`TableAdapter` 在 db 包无法返回 `TableIterator` 类型
2. **接口不统一**：`SimpleIterator` 和 `TableIterator` 是两套独立的迭代器接口
3. **功能缺失**：反向迭代未实现、`readTs` 时间戳过滤未实现

## 设计目标

1. **统一迭代器接口** - 所有表迭代器实现同一接口
2. **解决可见性问题** - 公开接口，内部实现保持 protected
3. **支持反向迭代** - 正向/反向遍历
4. **支持 readTs 过滤** - MVCC 时间戳过滤

## 架构设计

### 接口层次

```
TableIter (public interface, table 包)
    ↑
    ├── TableIterator (protected, table 包) - SSTable 迭代器
    ├── MemTableIter (public, db 包) - MemTable 迭代器
    └── MockTableIter (public, db 包) - Mock 迭代器

SimpleIterator (public open class, db 包)
    ↑
    └── TableIterWrapper (public, db 包) - 包装 TableIter 为 SimpleIterator
```

### 数据流

```
Iterator (用户 API)
    │
    ├── PendingWritesIterator (事务写入)
    │
    ├── MemTableIter (MemTable)
    │
    └── TableIterWrapper
            │
            └── TableIterator
                    │
                    └── BlockIterator
```

## 接口定义

### TableIter 接口

```cangjie
// src/table/table_iter.cj
package badgercj.table

public interface TableIter {
    func seekFirst(): Unit              // 定位到第一个
    func seekLast(): Unit               // 定位到最后一个
    func seek(key: Array<Byte>): Unit   // 定位到指定 key
    func next(): Unit                   // 向前移动
    func prev(): Unit                   // 向后移动
    func isValid(): Bool                // 是否有效
    func key(): Array<Byte>             // 当前 key
    func value(): Array<Byte>           // 当前 value
    func valueStruct(): ?ValueStruct    // 当前 ValueStruct
}
```

### SimpleIterator 保持不变

```cangjie
// src/db/merge_iterator.cj
public open class SimpleIterator {
    public open func valid(): Bool { ... }
    public open func key(): Array<Byte> { ... }
    public open func value(): Array<Byte> { ... }
    public open func next(): Unit { ... }
    public open func rewind(): Unit { ... }
    public open func seek(key: Array<Byte>): Unit { ... }
}
```

### TableIterWrapper 包装器

```cangjie
// src/db/table_iter_wrapper.cj
package badgercj.db

import badgercj.table.*

public class TableIterWrapper <: SimpleIterator {
    private let iter: TableIter
    private let reverse: Bool
    
    public init(iter: TableIter, reverse!: Bool = false) {
        super()
        this.iter = iter
        this.reverse = reverse
        if (reverse) {
            iter.seekLast()
        } else {
            iter.seekFirst()
        }
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
    public override func seek(key: Array<Byte>): Unit { iter.seek(key) }
}
```

## 组件改动

### table 包

| 文件 | 改动 |
|------|------|
| `table_iter.cj` | **新建** - 公开接口定义 |
| `table_iterator.cj` | 实现 `TableIter` 接口 |
| `block_iterator.cj` | 添加 `prev()` 支持 |
| `table.cj` | `newIterator()` 返回 `TableIter` |
| `table_interface.cj` | 添加 `newIterator(): TableIter` |

### db 包

| 文件 | 改动 |
|------|------|
| `table_iter_wrapper.cj` | **新建** - 包装器 |
| `table_interface_iterator.cj` | **删除** - 替换为 wrapper |
| `table_adapter.cj` | `newIterator()` 返回 `TableIter` |
| `mock_table.cj` | 实现 `newIterator()` |
| `memtable_iterator.cj` | 改为实现 `TableIter` |
| `level_handler.cj` | 使用 `TableIterWrapper` |
| `iterator.cj` | 支持反向迭代 |

### 删除的文件

| 文件 | 原因 |
|------|------|
| `table_interface_iterator.cj` | 替换为 `table_iter_wrapper.cj` |
| `mock_table_iterator.cj` | 替换为 `MockTableIter` 实现 `TableIter` |

## 实现细节

### BlockIterator 添加 prev()

```cangjie
// src/table/block_iterator.cj
protected class BlockIterator {
    // 现有字段...
    
    public func prev(): Unit {
        if (currentIdx > 0) {
            currentIdx--
            updateCurrent()
        } else {
            valid_ = false
        }
    }
}
```

### TableIterator 完整实现

```cangjie
// src/table/table_iterator.cj
protected class TableIterator <: TableIter {
    private let table: Table
    private var blockIdx: Int64
    private var blockIter: BlockIterator
    
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
    
    // ... 其他方法
}
```

### readTs 过滤

`TableInterface.get()` 已经支持 `readTs`，迭代器层面需要在 `Iterator.parseItem()` 中过滤：

```cangjie
// src/db/iterator.cj
private func parseItem(): Unit {
    while (iitr.valid()) {
        let key = iitr.key()
        let ts = parseTs(key)
        
        // readTs 过滤
        if (ts > readTs) {
            iitr.next()
            continue
        }
        
        // ... 其他处理
        break
    }
}
```

## 测试计划

### 单元测试

| 测试 | 说明 |
|------|------|
| `testTableIterForward` | 正向迭代 |
| `testTableIterBackward` | 反向迭代 |
| `testTableIterSeek` | seek 定位 |
| `testTableIterReadTs` | readTs 过滤 |
| `testIteratorAfterReopen` | 重新打开后迭代 |

### 集成测试

| 测试 | 说明 |
|------|------|
| `testIteratorFullCycle` | 完整迭代周期 |
| `testMergeIterator` | 合并迭代器 |
| `testReverseIterator` | 反向迭代器 |

## 风险与注意事项

### 风险

1. **改动范围大** - 涉及 table 和 db 两个包
2. **回归风险** - 现有测试可能受影响

### 缓解措施

1. **分步实现** - 先修复正向迭代，再添加反向支持
2. **增量测试** - 每步完成后运行全量测试

## 时间估算

| 阶段 | 预计时间 |
|------|---------|
| TableIter 接口定义 | 0.5 小时 |
| BlockIterator 添加 prev() | 1 小时 |
| TableIterator 实现 | 1 小时 |
| TableIterWrapper 实现 | 0.5 小时 |
| 集成和测试 | 2 小时 |
| **总计** | **5 小时** |

## 参考

- Go badger iterator.go
- Go badger table/iterator.go