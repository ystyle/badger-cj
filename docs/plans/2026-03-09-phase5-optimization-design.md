# Phase 5: 性能优化与基准测试设计

**阶段状态：** ✅ 已完成  
**开始时间：** 2026-03-09  
**完成时间：** 2026-03-10  
**目标：** 建立性能基线，优化关键路径，验证性能目标

---

## 概述

Phase 5 专注于性能优化和基准测试，确保 badger-cj 在性能上接近 Go BadgerDB v4 的水平。

### 目标

1. **性能基线** - 为核心操作建立性能基准
2. **性能优化** - 基于测试结果优化关键路径
3. **性能对比** - 与 Go BadgerDB v4 进行对比测试

### 最终性能对比（Go vs Cangjie）

| 操作 | Go Badger v4 | Cangjie badger-cj | 比率 |
|------|-------------|------------------|------|
| **Skiplist Put** | 976 ns | 2,469 ns | **2.5x** |
| **DB Set** | 4,566 ns | 14,730 ns | **3.2x** |
| **DB Get** | 708 ns | 3,901 ns | **5.5x** |

**结论：** 所有操作性能差距控制在 2-6 倍，对于新语言来说是合理的性能表现。

---

## Week 1: Benchmark 基础设施

### Task 1: Skiplist 基准测试 ✅

**文件：** `src/db/skiplist_bench.cj`

**测试用例：**
- `benchPut` - 1000 次随机写入
- `benchGet` - 1000 次随机读取（数据预加载）

**结果：**
- Put: 2,469 ns/op（Go: 976 ns）
- Get: 3,804 ns/op

### Task 2: DB 基准测试 ✅

**文件：** `src/db/db_bench.cj`

**测试用例：**
- `benchDBSet` - 单次 DB Set 操作
- `benchDBGet` - 单次 DB Get 操作

**结果：**
- DB Set: 14,730 ns/op（Go: 4,566 ns）
- DB Get: 3,901 ns/op（Go: 708 ns）

---

## Week 2: 性能优化

### 优化 1: ReadWriteLock 替换 Mutex ✅

**问题：** `db.get()` 使用 `Mutex`（排他锁），序列化所有读取操作

**解决方案：** 改为 `ReadWriteLock`

**代码变更：** `src/db/db.cj`
```cangjie
// 之前
private let lock: Mutex

// 之后  
private let lock: ReadWriteLock

// get() 使用读锁
lock.readLock.lock()
// ...
lock.readLock.unlock()

// set() 使用写锁
lock.writeLock.lock()
// ...
lock.writeLock.unlock()
```

**效果：** 并发读取性能提升

### 优化 2: WAL BufferedOutputStream ✅

**问题：** 每次 WAL 写入都是同步 I/O

**解决方案：** 使用 `BufferedOutputStream` 缓冲

**代码变更：** `src/db/wal.cj`
```cangjie
// 添加缓冲输出流
private var bufferedOut: ?BufferedOutputStream<File>

// 打开时创建缓冲
wal.bufferedOut = BufferedOutputStream<File>(f, 8192)

// 写入使用缓冲
let out = bufferedOut ?? throw Exception("WAL file not open")
out.write(encoded)
```

**效果：** 批量 I/O 减少系统调用

### 优化 3: findGe 替代全表扫描 ✅ **核心优化**

**问题：** `getWithTs()` 使用 `SkipIterator` 全表扫描，O(n) 复杂度

**原始代码：**
```cangjie
public func getWithTs(userKey: Array<Byte>, readTs: UInt64): ?ValueStruct {
    var bestVs: ?ValueStruct = None
    var bestTs: UInt64 = 0
    
    let iter = SkipIterator(table)
    while (iter.hasNext()) {  // O(n) 遍历！
        if (let Some((key, vs)) <- iter.next()) {
            if (sameKey(key, keyWithTs(userKey, readTs))) {
                let ts = parseTs(key)
                if (ts <= readTs && ts > bestTs) {
                    bestTs = ts
                    bestVs = Some(vs)
                }
            }
        }
    }
    bestVs
}
```

**Go 参考实现：**
```go
func (s *Skiplist) Get(key []byte) y.ValueStruct {
    n, _ := s.findNear(key, false, true) // findGreaterOrEqual - O(log n)!
    if n == nil {
        return y.ValueStruct{}
    }
    nextKey := s.arena.getKey(n.keyOffset, n.keySize)
    if !y.SameKey(key, nextKey) {
        return y.ValueStruct{}
    }
    // ...
}
```

**解决方案：** 
1. 在 Skiplist 添加 `findGe()` 方法（类似 Go 的 `findNear(key, false, true)`）
2. 使用 O(log n) 的跳跃查找替代 O(n) 的迭代

**代码变更：** `src/skiplist/skiplist.cj`
```cangjie
/**
 * 查找 >= key 的节点 (类似 Go 的 findNear(key, false, true))
 */
public func findGe(key: Array<Byte>): ?Node {
    var x = head
    var level = getHeight() - 1
    
    while (level >= 0) {
        let nextOffset = x.getNextOffset(level)
        if (nextOffset == 0) {
            level--
            continue
        }
        
        let n = Node(arena, nextOffset)
        let cmp = compareKeys(key, n.getKey())
        
        if (cmp > 0) {
            x = n
        } else if (cmp == 0) {
            return Some(n)
        } else {
            level--
        }
    }
    
    let nextOffset = x.getNextOffset(0)
    if (nextOffset == 0) {
        return None
    }
    Some(Node(arena, nextOffset))
}
```

**代码变更：** `src/db/memtable.cj`
```cangjie
public func getWithTs(userKey: Array<Byte>, readTs: UInt64): ?ValueStruct {
    let seekKey = keyWithTs(userKey, readTs)
    
    let node = table.findGe(seekKey)  // O(log n)!
    if (let Some(n) <- node) {
        let key = n.getKey()
        if (sameKey(key, seekKey)) {
            let ts = parseTs(key)
            if (ts <= readTs) {
                let value = n.getValue()
                let offset = UInt32(value >> 32)
                let size = UInt16(value & 0xFFFFu64)
                let encoded = arena.getBytes(offset, size)
                return ValueStruct.decode(encoded)
            }
        }
    }
    None
}
```

**效果：** DB Get 从 **1.97ms → 3.9µs**，提升 **500 倍**！

---

## Week 3: 其他优化

### 优化 4: DisableWAL 选项 ✅

**用途：** 性能测试时禁用 WAL

**代码变更：** `src/db/options.cj`
```cangjie
public class DBOptions {
    public let DisableWAL: Bool  // For performance testing
    
    public init(
        // ...
        disableWAL!: Bool = false
    ) {
        this.DisableWAL = disableWAL
    }
}
```

**代码变更：** `src/db/memtable.cj`
```cangjie
public func put(key: Array<Byte>, vs: ValueStruct): Unit {
    if (!opt.DisableWAL) {
        wal.write(key, vs)
    }
    // ...
}
```

### 优化 5: LinkedBlockingQueue 替代 ConcurrentLinkedQueue ✅

**问题：** `ConcurrentLinkedQueue` 无容量限制，可能内存溢出

**解决方案：** 改用 `LinkedBlockingQueue(1000)` 限制队列大小

**代码变更：** `src/db/db.cj`
```cangjie
// 之前
public let writeCh: ConcurrentLinkedQueue<WriteRequest>

// 之后
public let writeCh: LinkedBlockingQueue<WriteRequest>

// 初始化
this.writeCh = LinkedBlockingQueue<WriteRequest>(1000)
```

---

## 性能对比详情

### 测试环境

- **CPU:** AMD Ryzen 7 7840HS
- **OS:** Linux
- **Go 版本:** badger v4
- **Cangjie 版本:** cjpm with -O2

### Go 基准测试命令

```bash
cd /home/ystyle/Projects/badger

# Skiplist Put
go test -run=^$ -bench=BenchmarkWrite -benchmem -cpu=1 ./skl/

# DB Set
go test -bench=DBSet -benchmem -cpu=1 /tmp/db_bench_test.go

# DB Get
go test -bench=DBGet -benchmem -cpu=1 /tmp/db_bench_test.go
```

### Cangjie 基准测试命令

```bash
cd /home/ystyle/Projects/Cangjie/badger-cj

# Skiplist
cjpm bench --filter=SkiplistBench

# DB
cjpm bench --filter=DBBench
```

### 详细结果

#### Skiplist Put
- **Go:** 975.8 ns/op, 64 B/op, 7 allocs/op
- **Cangjie:** 2,469 ns/op (2.5x slower)

#### DB Set
- **Go:** 4,566 ns/op, 1838 B/op, 40 allocs/op
- **Cangjie:** 14,730 ns/op (3.2x slower)

#### DB Get
- **Go:** 708.3 ns/op, 508 B/op, 8 allocs/op
- **Cangjie:** 3,901 ns/op (5.5x slower)

---

## 提交记录

| 提交 | 日期 | 描述 |
|------|------|------|
| `3156811` | 2026-03-10 | 添加 Go 可对比的基准测试，优化 db lock |
| `980365e` | 2026-03-10 | WAL 使用 BufferedOutputStream，添加 DisableWAL 选项 |
| `d7d350f` | 2026-03-10 | **核心优化**: 使用 findGe 实现 O(log n) 版本查找 |
| `d6d2f26` | 2026-03-10 | 修复 WAL 崩溃恢复测试 |

---

## 验收标准

### 功能验收 ✅

- ✅ 所有现有测试仍然通过（128/128）
- ✅ 新增 Benchmark 测试 4 个
- ✅ Benchmark 测试覆盖核心操作

### 性能验收 ✅

| 操作 | 目标 | 实际 | 状态 |
|------|------|------|------|
| 单次写入延迟 | < 20µs | 14.7µs | ✅ |
| 单次读取延迟 | < 10µs | 3.9µs | ✅ |
| 与 Go 性能比率 | < 10x | 5.5x | ✅ |

---

## 经验总结

### 关键发现

1. **算法复杂度最重要** - O(n) → O(log n) 的优化带来 500 倍性能提升
2. **参考 Go 实现** - Go 的 `findNear` 设计是性能优化的关键
3. **锁粒度影响大** - ReadWriteLock 对读多写少场景很有效
4. **I/O 缓冲必要** - WAL 使用缓冲可显著减少系统调用

### 仓颉性能特点

1. **基础性能良好** - 2-6 倍的差距对新语言来说是合理的
2. **并发原语完善** - ReadWriteLock、Atomic 类型都有良好支持
3. **编译优化** - `-O2` 编译选项有效
4. **Benchmark 框架** - `@Bench` 宏使用方便

---

## 后续优化方向（已完成）

### 5. 无锁并发 SkipList ✅ **2026-03-11 完成**

**问题：** 原实现 `casNextOffset` 是伪 CAS（先读后写），多线程写入会数据损坏

**解决方案：** 
1. 新增 `AtomicStorage` 类，分离 value/tower 到独立的原子存储
2. 使用 `compareAndSwap()` 实现真正的 CAS
3. CAS 失败后重新查找插入位置

**代码变更：** 
- `src/skiplist/atomic_storage.cj` - 新增原子存储管理类
- `src/skiplist/skiplist.cj` - 无锁并发实现，CAS 循环
- `src/skiplist/node.cj` - 通过 AtomicStorage 访问 value/tower

**性能结果：**
```
Concurrent Write:  457 ns/op  (16 threads, 2.1M ops/sec)
Concurrent Read:   116 ns/op  (16 threads, 8.5M ops/sec)
Sequential Write: 1234 ns/op  (1 thread, 810K ops/sec)
Sequential Read:  3576 ns/op  (1 thread, 280K ops/sec)
```

**对比 Go:**
| 操作 | Go | Cangjie | 比率 |
|------|-----|---------|------|
| Concurrent Write | ~250 ns | 457 ns | 1.8x |
| Concurrent Read | ~96 ns | 116 ns | 1.2x |

**结论：** 无锁并发实现成功，性能接近 Go 版本

---

## 优化历史

### 优化 1-4: Phase 5 初始优化 ✅

---

**文档版本：** v2.0  
**最后更新：** 2026-03-11  
**维护者：** AI Code Agent
