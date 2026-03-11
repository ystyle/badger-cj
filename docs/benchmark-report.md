# Badger-cj 性能基准测试报告

**测试日期：** 2026-03-11  
**版本：** 无锁并发 SkipList 版本  
**测试环境：** Linux x86_64, AMD Ryzen 7 7840HS, cjHeapSize=4gb

---

## 概述

本文档记录 badger-cj 与 Go BadgerDB v4 的性能对比测试结果。

### 运行方式

```bash
# Cangjie benchmark (单线程)
cjpm bench

# Cangjie 性能测试 (多线程并发)
cjpm build
cjHeapSize=4gb ./target/release/bin/badgercj.examples.skiplist_perf

# Go benchmark (并发)
cd ~/Projects/badger
go test -run=^$ -bench=BenchmarkWrite -benchmem ./skl/
go test -bench=BenchmarkReadWrite -benchmem ./skl/
```

---

## Go vs Cangjie 性能对比

### 1. 单线程基准测试 (cjpm bench)

| 操作 | Go Badger v4 | Cangjie badger-cj | 比率 |
|------|-------------|------------------|------|
| **Skiplist Put** | 976 ns/op | 2,469 ns/op | **2.5x** |
| **Skiplist Get** | - | 3,804 ns/op | - |
| **DB Set** | 4,566 ns/op | 14,730 ns/op | **3.2x** |
| **DB Get** | 708 ns/op | 3,901 ns/op | **5.5x** |

**注：** 单线程测试包含了创建 Arena/AtomicStorage 的开销

### 2. 多线程并发测试 (独立可执行文件)

| 操作 | Go (16线程) | Cangjie (16线程) | 比率 |
|------|------------|-----------------|------|
| **Concurrent Write** | ~250 ns/op | 457 ns/op | **1.8x** |
| **Concurrent Read** | ~96 ns/op | 116 ns/op | **1.2x** |
| **Sequential Write** | - | 1,234 ns/op | - |
| **Sequential Read** | - | 3,576 ns/op | - |

**测试条件：** 5000 ops, 16 threads, 4GB heap

### 3. 详细并发测试数据

```
=== Skiplist Performance Test ===
Operations: 5000, Threads: 16

--- Concurrent Write ---
Total time: 2 ms
Per op: 457 ns/op
Throughput: 2,184,367 ops/sec

--- Concurrent Read ---
Total time: 0 ms
Per op: 116 ns/op
Throughput: 8,576,329 ops/sec

--- Sequential Write ---
Total time: 6 ms
Per op: 1,234 ns/op
Throughput: 810,372 ops/sec

--- Sequential Read ---
Total time: 17 ms
Per op: 3,576 ns/op
Throughput: 279,642 ops/sec
```

---

## 无锁并发实现效果

### 优化前 vs 优化后

| 指标 | 优化前 (伪CAS) | 优化后 (真CAS) |
|------|--------------|---------------|
| **并发安全** | ❌ 数据损坏风险 | ✅ 无锁并发安全 |
| **写性能** | ~380 ns/op | ~457 ns/op |
| **读性能** | - | ~116 ns/op |

### 关键改进

1. **分离 AtomicStorage**
   - `values: Array<AtomicUInt64>` - value 原子存储
   - `towers: Array<Array<AtomicUInt32>>` - tower 原子存储

2. **真正的 CAS 操作**
   ```cangjie
   public func casNextOffset(nodeIdx: Int64, level: Int64, old: UInt32, new: UInt32): Bool {
       towers[nodeIdx][level].compareAndSwap(old, new)  // 真正的原子 CAS
   }
   ```

3. **CAS 循环重试**
   ```cangjie
   while (true) {
       if (prevNode.casNextOffset(i, nextOffsets[i], nodeOffset)) {
           break  // CAS 成功
       }
       // CAS 失败，重新查找位置
       let (p, n) = findSpliceForLevel(key, prevOff, i)
       prevOffsets[i] = p
       nextOffsets[i] = n
   }
   ```

---

## 性能优化记录

### 优化 1: findGe O(log n) 查找 - **核心优化**

**问题：** `getWithTs()` 使用 SkipIterator 全表扫描，O(n) 复杂度

**优化前：**
```cangjie
let iter = SkipIterator(table)
while (iter.hasNext()) { ... }  // O(n)
```

**优化后：**
```cangjie
let node = table.findGe(seekKey)  // O(log n)
```

**效果：** DB Get 从 **1.97ms → 3.9us**，提升 **500 倍**

### 优化 2: ReadWriteLock

**问题：** `db.get()` 使用 Mutex（排他锁）

**优化：** 改为 ReadWriteLock

**效果：** 并发读取无锁竞争

### 优化 3: WAL BufferedOutputStream

**问题：** 每次 WAL 写入都是同步 I/O

**优化：** 使用 BufferedOutputStream(8192)

**效果：** 减少 I/O 系统调用

### 优化 4: LinkedBlockingQueue

**问题：** ConcurrentLinkedQueue 无容量限制

**优化：** 改用 LinkedBlockingQueue(1000)

**效果：** 防止内存溢出

---

## 性能目标达成情况

| 操作 | 目标 | 实测 | 状态 |
|------|------|------|------|
| 单次写入延迟 | < 20 us | 14.7 us | 达标 |
| 单次读取延迟 | < 10 us | 3.9 us | 达标 |
| 与 Go 性能比率 | < 10x | 5.5x | 达标 |

---

## Benchmark 测试文件

| 文件 | 测试数 | 描述 |
|------|--------|------|
| `src/db/skiplist_bench.cj` | 2 | Skiplist Put/Get |
| `src/db/db_bench.cj` | 2 | DB Set/Get |

---

## 经验总结

### 关键发现

1. **算法复杂度最重要** - O(n) to O(log n) = 500x improvement
2. **参考 Go 实现** - Go's findNear design is key
3. **锁粒度影响大** - ReadWriteLock effective for read-heavy workloads
4. **I/O 缓冲必要** - BufferedOutputStream reduces syscalls significantly

### 仓颉性能特点

1. **基础性能良好** - 2-6x gap is reasonable for new language
2. **并发原语完善** - ReadWriteLock, Atomic types well supported
3. **编译优化** - -O2 option effective
4. **Benchmark 框架** - @Bench macro easy to use

---

## 提交记录

| 提交 | 日期 | 描述 |
|------|------|------|
| `3156811` | 2026-03-10 | Add Go-comparable benchmarks, optimize db lock |
| `980365e` | 2026-03-10 | WAL BufferedOutputStream, DisableWAL option |
| `d7d350f` | 2026-03-10 | Core optimization: findGe O(log n) lookup |
| `d6d2f26` | 2026-03-10 | Fix WAL crash recovery test |

---

**文档版本：** v2.0  
**最后更新：** 2026-03-10
