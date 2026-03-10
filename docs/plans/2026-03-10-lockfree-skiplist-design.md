# SkipList 无锁并发设计

**日期**: 2026-03-10
**状态**: ✅ 已完成
**优先级**: 高
**完成日期**: 2026-03-11

## 1. 背景

### 当前问题

仓颉版 SkipList 声称"并发实现"，但实际上：

1. `casNextOffset` 是伪 CAS（先读后写，非原子）
2. `add()` 无锁保护，多线程写入会数据损坏
3. **既不并发也不同步**

### Go 版本参考

Go 版本（`/home/ystyle/Projects/badger/skl/skl.go`）是真正的无锁并发：

```go
type node struct {
    value atomic.Uint64              // 原子
    tower [maxHeight]atomic.Uint32   // 每层指针都是原子的
}

func (s *node) casNextOffset(h int, old, val uint32) bool {
    return s.tower[h].CompareAndSwap(old, val)  // 真正的 CAS
}
```

Put 操作使用 CAS 循环：
```go
for {
    if prev[i].casNextOffset(i, nextOffset, newNodeOffset) {
        break  // 成功
    }
    // 失败，重新查找位置
    prev[i], next[i] = s.findSpliceForLevel(key, prev[i], i)
}
```

## 2. 设计目标

1. **完全无锁并发** - tower 和 value 都原子化
2. **内存可见性保证** - CAS 作为 release 屏障
3. **与 Go 版本等价** - 正确性和性能
4. **最小化破坏** - Arena 内存布局可变，接口兼容

## 3. 详细方案

### 3.1 核心思路

利用 **CAS 操作的内存屏障语义**：

```
写入顺序：key（Arena）→ value.store → tower[level].CAS
读取顺序：tower[level].load → value.load → key（Arena）
```

- CAS 成功 = release 语义，之前的写入对其他线程可见
- load 操作 = acquire 语义，能看到 CAS 之前的写入

### 3.2 新增 AtomicStorage 类

管理分离的原子存储：

```cangjie
package badgercj.skiplist

import std.sync.*
import std.collection.*

public class AtomicStorage {
    private let values: Array<AtomicUInt64>   // value 存储
    private let towers: Array<Array<AtomicUInt32>>  // tower[节点][层级]
    private let capacity: Int64
    private let nodeCount: AtomicInt64
    
    public init(capacity: Int64) {
        this.capacity = capacity
        this.nodeCount = AtomicInt64(0)
        this.values = Array<AtomicUInt64>(capacity, { _ => AtomicUInt64(0) })
        this.towers = Array<Array<AtomicUInt32>>(capacity, { _ => 
            Array<AtomicUInt32>(MAX_HEIGHT, { _ => AtomicUInt32(0) })
        })
    }
    
    public func allocNode(): Int64 {
        let idx = nodeCount.fetchAdd(1)
        if (idx >= capacity) {
            throw Exception("AtomicStorage overflow")
        }
        return idx
    }
    
    public func setValue(nodeIdx: Int64, value: UInt64): Unit {
        values[nodeIdx].store(value)
    }
    
    public func getValue(nodeIdx: Int64): UInt64 {
        values[nodeIdx].load()
    }
    
    public func getTower(nodeIdx: Int64, level: Int64): AtomicUInt32 {
        towers[nodeIdx][level]
    }
    
    public func casTower(nodeIdx: Int64, level: Int64, old: UInt32, new: UInt32): Bool {
        towers[nodeIdx][level].compareAndSwap(old, new)
    }
}
```

### 3.3 重构 Node

Node 不再完全在 Arena 中：

```cangjie
public class Node {
    private let arena: Arena
    private let offset: UInt32        // Arena 中元数据位置
    private let atomicIdx: Int64      // AtomicStorage 索引
    private let atomicStorage: AtomicStorage
    
    // Arena 中存储（写入后不变）：
    // - keyOffset (UInt32)
    // - keySize (UInt16)
    // - height (UInt16)
    
    public func getKey(): Array<Byte> {
        let keyOffset = arena.getU32(offset + 8)
        let keySize = arena.getU16(offset + 12)
        arena.getBytes(keyOffset, keySize)
    }
    
    public func getHeight(): UInt16 {
        arena.getU16(offset + 14)
    }
    
    // 原子操作
    public func getValue(): UInt64 {
        atomicStorage.getValue(atomicIdx)
    }
    
    public func setValue(value: UInt64): Unit {
        atomicStorage.setValue(atomicIdx, value)
    }
    
    public func getNextOffset(level: Int64): UInt32 {
        atomicStorage.getTower(atomicIdx, level).load()
    }
    
    public func casNextOffset(level: Int64, old: UInt32, new: UInt32): Bool {
        atomicStorage.casTower(atomicIdx, level, old, new)
    }
}
```

### 3.4 重构 Skiplist.Put

使用 CAS 循环：

```cangjie
public func add(key: Array<Byte>, value: UInt64): Unit {
    let h = randomHeight()
    
    // ... 更新高度 ...
    
    // 查找插入位置
    var prev = Array<Node>(MAX_HEIGHT, repeat: head)
    var next = Array<UInt32>(MAX_HEIGHT, repeat: 0)
    
    // ... 查找逻辑 ...
    
    // 分配新节点
    let atomicIdx = atomicStorage.allocNode()
    let nodeOffset = arena.putNode(h)
    let newNode = Node(arena, nodeOffset, atomicIdx, atomicStorage)
    
    // 写入 immutable 字段
    // ...
    
    // 写入 value
    newNode.setValue(value)
    
    // 逐层插入（CAS 循环）
    for (i in 0..h) {
        for {
            newNode.setNextOffset(i, next[i])  // 设置新节点的 next
            
            if (prev[i].casNextOffset(i, next[i], nodeOffset)) {
                break  // CAS 成功
            }
            
            // CAS 失败，重新查找
            prev[i], next[i] = findSpliceForLevel(key, prev[i], i)
            
            if (prev[i] == next[i]) {
                // key 已存在，更新 value
                prev[i].setValue(value)
                return
            }
        }
    }
}
```

## 4. 内存布局对比

### Go 版本

```
Arena 连续内存:
┌────────────────────────────────────┐
│ Node: value|keyOff|keySize|height  │
│       |tower[0]|tower[1]|...       │
├────────────────────────────────────┤
│ Node: ...                          │
└────────────────────────────────────┘
```

### 当前仓颉版本

```
Arena 连续内存（但无原子保证）:
┌────────────────────────────────────┐
│ Node: value|keyOff|keySize|height  │
│       |tower[0]|tower[1]|...       │
├────────────────────────────────────┤
│ Node: ...                          │
└────────────────────────────────────┘
```

### 新方案（分离原子存储）

```
Arena（非原子部分）:
┌────────────────────────────────────┐
│ Node: <pad>|keyOff|keySize|height  │
├────────────────────────────────────┤
│ Node: ...                          │
└────────────────────────────────────┘

AtomicStorage（原子部分）:
values:  [AtomicU64][AtomicU64]...
towers:  [[AtomicU32 x 20]][[AtomicU32 x 20]]...
```

**代价**：内存布局不连续，可能影响缓存局部性
**收益**：真正的无锁并发

## 5. 实现步骤

| 步骤 | 任务 | 文件 | 时间 |
|------|------|------|------|
| 1 | 创建 AtomicStorage 类 | `src/skiplist/atomic_storage.cj` | 30分钟 |
| 2 | 重构 Node 类 | `src/skiplist/node.cj` | 1小时 |
| 3 | 添加 findSpliceForLevel | `src/skiplist/skiplist.cj` | 30分钟 |
| 4 | 重构 Put 为 CAS 循环 | `src/skiplist/skiplist.cj` | 1小时 |
| 5 | 更新 Skiplist 初始化 | `src/skiplist/skiplist.cj` | 15分钟 |
| 6 | 并发测试验证 | `src/skiplist/skiplist_test.cj` | 1小时 |
| **总计** | | | **4-5小时** |

## 6. 风险和权衡

### 风险

1. **内存碎片** - 分离存储降低缓存局部性
2. **预分配容量** - AtomicStorage 需要预分配，可能浪费或溢出
3. **复杂度增加** - 两套存储系统，调试更困难

### 权衡

| 方面 | 加锁方案 | 无锁方案 |
|------|----------|----------|
| 实现复杂度 | 低 | 中 |
| 性能（低竞争） | 相近 | 相近 |
| 性能（高竞争） | 较差 | 较好 |
| 内存效率 | 好 | 稍差 |
| 正确性保证 | 简单可靠 | 需要仔细验证 |

### 建议的验收标准

1. 并发压力测试：20线程 x 10000次写入，无数据损坏
2. 功能测试：所有现有测试通过
3. 性能测试：相比加锁版本，高并发场景吞吐量提升 > 50%

## 7. 待确认

1. AtomicStorage 容量策略：固定大小 vs 动态扩容？
2. 是否需要引用计数（Go 版本的 IncrRef/DecrRef）？
3. 迭代器是否需要修改？

---

**审批意见**:

_请确认后开始实现_
