# Badger-cj 性能基准测试报告

**测试日期：** 2026-03-10  
**版本：** Phase 5 完成版本（128 测试通过）  
**测试环境：** Linux x86_64, AMD Ryzen 7 7840HS

---

## 概述

本文档记录 badger-cj 与 Go BadgerDB v4 的性能对比测试结果。

### 运行方式

```bash
# Cangjie benchmark
cjpm bench

# Go benchmark
cd /home/ystyle/Projects/badger
go test -run=^$ -bench=BenchmarkWrite -benchmem -cpu=1 ./skl/
go test -bench=DBSet -benchmem -cpu=1 /tmp/db_bench_test.go
go test -bench=DBGet -benchmem -cpu=1 /tmp/db_bench_test.go
```

---

## Go vs Cangjie 性能对比

### 最终结果

| 操作 | Go Badger v4 | Cangjie badger-cj | 比率 |
|------|-------------|------------------|------|
| **Skiplist Put** | 976 ns/op | 2,469 ns/op | **2.5x** |
| **Skiplist Get** | - | 3,804 ns/op | - |
| **DB Set** | 4,566 ns/op | 14,730 ns/op | **3.2x** |
| **DB Get** | 708 ns/op | 3,901 ns/op | **5.5x** |

### 详细数据

#### Skiplist Put
```
Go:      BenchmarkWrite-16    1215837    975.8 ns/op    64 B/op    7 allocs/op
Cangjie: benchPut              Median     2.469 ms (1000 ops) = 2469 ns/op
```

#### DB Set
```
Go:      BenchmarkDBSet-16    262935    4566 ns/op    1838 B/op    40 allocs/op
Cangjie: benchDBSet            Median    14.42 us
```

#### DB Get
```
Go:      BenchmarkDBGet-16    1621920    708.3 ns/op    508 B/op    8 allocs/op
Cangjie: benchDBGet            Median    3.901 us
```

**结论：** 所有操作性能差距控制在 2-6 倍，对于新语言来说是合理的性能表现。

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
