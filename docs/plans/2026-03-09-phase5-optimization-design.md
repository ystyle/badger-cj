# Phase 5: 性能优化与基准测试

**创建时间：** 2026-03-09  
**目标：** 建立性能基线，优化关键路径，验证性能目标

---

## 概述

Phase 5 专注于性能优化和基准测试，确保 badger-cj 在性能上接近 Go BadgerDB v4 的水平。

### 目标

1. **性能基线** - 为核心操作建立性能基准
2. **性能优化** - 基于测试结果优化关键路径
3. **性能对比** - 与 Go BadgerDB v4 进行对比测试

### 性能目标（参考 Go BadgerDB v4）

| 操作 | 目标性能 | Go BadgerDB 参考值 |
|------|---------|-------------------|
| 单次写入（小值） | < 10µs | ~5µs |
| 单次读取（命中） | < 5µs | ~2µs |
| 范围扫描（1000键） | < 1ms | ~500µs |
| 事务提交（10键） | < 50µs | ~30µs |
| 并发写入（1000 op/s） | > 1000 op/s | ~2000 op/s |

---

## Week 1: Benchmark 基础设施

### Task 1: Benchmark 测试框架

**目标：** 使用仓颉内置的 `@Bench` 宏建立性能测试

**关键特性：**
- ✅ 使用 `@Bench` 宏标记性能测试
- ✅ 使用 `@Strategy` 宏生成测试数据
- ✅ 使用 `@Measure` 宏自定义测量源（时间、CPU 周期等）
- ✅ 支持参数化测试（不同数据规模）

**示例：**
```cangjie
@Test
class MemTableBenchmark {
    let db: DB
    var key: Array<Byte> = []
    var value: Array<Byte> = []
    
    init() {
        db = DB.open(DBOptions(dir: "/tmp/bench_memtable"))
    }
    
    @Strategy[size in [100, 1000, 10000]]
    func generateData(size: Int64): Unit {
        key = "key_${size}".toArray()
        value = Array<Byte>(size, repeat: 65)  // 'A'
    }
    
    @Bench
    func memTablePut() {
        db.set(key, value)
    }
    
    @Bench
    func memTableGet() {
        db.get(key)
    }
}
```

**测试文件：**
- `src/db/memtable_bench.cj` - MemTable 读写性能
- `src/db/transaction_bench.cj` - 事务性能
- `src/db/iterator_bench.cj` - 迭代器性能
- `src/db/concurrent_bench.cj` - 并发性能

### Task 2: Benchmark 数据生成

**目标：** 创建各种规模和模式的测试数据

**数据策略：**
- 小键（10 字节） + 小值（100 字节）
- 中键（100 字节） + 中值（1KB）
- 大键（1KB） + 大值（10KB）
- 随机访问模式
- 顺序访问模式

---

## Week 2: 核心性能基准

### Task 3: MemTable 性能基准

**测试场景：**
1. **单次写入性能** - 测量 `set()` 的延迟
2. **单次读取性能** - 测量 `get()` 的延迟（命中/未命中）
3. **批量写入性能** - 测量连续写入的吞吐量
4. **内存分配开销** - 测量 Arena 分配速度

**预期发现：**
- MemTable 写入应该接近 O(log n)（Skiplist 特性）
- 读取应该也是 O(log n)
- Arena 分配应该是 O(1)

### Task 4: Transaction 性能基准

**测试场景：**
1. **只读事务** - 测量事务创建和读取开销
2. **写事务提交** - 测量 commit() 的延迟（不同冲突率）
3. **冲突检测开销** - 测量 Oracle 冲突检测成本
4. **WaterMark 更新** - 测量完成标记追踪成本

**预期发现：**
- 无冲突事务应该快速提交（< 50µs）
- 冲突检测应该在 O(n) 范围内（n = 读集 + 写集）
- WaterMark 更新应该是原子操作

### Task 5: Iterator 性能基准

**测试场景：**
1. **前向迭代** - 测量顺序扫描速度
2. **反向迭代** - 测量逆序扫描速度
3. **Seek 定位** - 测量随机定位速度
4. **前缀过滤** - 测量前缀扫描速度

**预期发现：**
- 顺序扫描应该接近内存访问速度
- Seek 应该是 O(log n)
- 前缀过滤应该能跳过不相关的键

### Task 6: 并发性能基准

**测试场景：**
1. **单线程性能** - 基准单线程吞吐量
2. **多线程扩展性** - 测量 2/4/8/16 线程的扩展性
3. **读写混合** - 测量不同读写比例的性能
4. **并发事务** - 测量并发事务吞吐量

**预期发现：**
- 多线程应该能线性扩展（直到锁竞争成为瓶颈）
- 读写混合应该优于纯写入（MVCC 优势）

---

## Week 3: 性能分析与优化

### Task 7: 性能热点识别

**工具：**
1. **Benchmark 报告** - 使用 `--report-format=html` 生成详细报告
2. **自定义测量源** - 使用 `@Measure[CpuCycles(), Perf()]` 分析 CPU 使用
3. **代码审查** - 手动识别潜在瓶颈

**关注点：**
- 时间戳嵌入/解析开销（`keyWithTs`/`parseTs`）
- 内存分配开销（Arena、ArrayList）
- 锁竞争（synchronized/Mutex）
- Skiplist 查找性能
- WaterMark 更新延迟

### Task 8: 优化策略

#### 优化 1: 减少时间戳操作开销

**问题：** `keyWithTs()` 和 `parseTs()` 在热路径中被频繁调用

**优化方案：**
```cangjie
// 当前实现（每次创建新数组）
public func keyWithTs(key: Array<Byte>, ts: UInt64): Array<Byte> {
    let result = Array<Byte>(key.size + 8, {i =>
        if (i < key.size) { key[i] } 
        else { ... }
    })
    return result
}

// 优化方案 1: 复用缓冲区（需要调用方保证线程安全）
public func keyWithTs(key: Array<Byte>, ts: UInt64, buffer: Array<Byte>): Array<Byte> {
    // 直接写入 buffer，避免分配
}

// 优化方案 2: 延迟解析（只在需要时解析时间戳）
class Item {
    let key: Array<Byte>
    var cachedTs: ?UInt64 = None  // 延迟缓存
    
    func version(): UInt64 {
        if (cachedTs.isNone) {
            cachedTs = parseTs(key)
        }
        return cachedTs.get()
    }
}
```

**预期收益：** 减少 20-30% 的写入延迟

#### 优化 2: 减少内存分配

**问题：** 频繁创建 `ArrayList<TxnEntry>` 和临时字节数组

**优化方案：**
```cangjie
// 当前实现（每次事务都创建新的 ArrayList）
class Transaction {
    var reads = ArrayList<Array<Byte>>()
    var writes = ArrayList<TxnEntry>()
}

// 优化方案: 对象池（复用 ArrayList）
class TransactionPool {
    let readsPool = ArrayList<ArrayList<Array<Byte>>>()
    let writesPool = ArrayList<ArrayList<TxnEntry>>()
    
    func acquire(): Transaction {
        // 从池中获取或创建新对象
    }
    
    func release(txn: Transaction): Unit {
        // 清空并归还到池中
    }
}
```

**预期收益：** 减少 10-20% 的内存分配开销

#### 优化 3: WaterMark 批量更新

**问题：** 每次 commit 都调用 `bumpCommitTs()` 中的 `setDoneUntil()`

**优化方案：**
```cangjie
// 当前实现（每次 commit 都更新）
func bumpCommitTs(commitTs: UInt64): Unit {
    commitMark.setDoneUntil(commitTs)
}

// 优化方案: 批量更新（累积后定期刷新）
class WaterMark {
    let pendingUpdates = AtomicUInt64(0)
    let lastFlush = AtomicUInt64(0)
    
    func setDoneUntil(val: UInt64): Unit {
        // 累积更新
        let old = pendingUpdates.load()
        if (val > old) {
            pendingUpdates.store(val)
        }
        
        // 定期刷新（每 100 次或 1ms）
        if (val - lastFlush.load() > 100) {
            commitMark.setDoneUntil(pendingUpdates.load())
            lastFlush.store(val)
        }
    }
}
```

**预期收益：** 减少原子操作开销 30-50%

#### 优化 4: Iterator 预取

**问题：** 每次迭代都调用 `next()` 导致频繁函数调用

**优化方案：**
```cangjie
// 当前实现（每次 next() 都解析）
func next(): Unit {
    // 解析下一个 item
}

// 优化方案: 预取批量数据
class Iterator {
    let prefetchBuffer = ArrayList<Item>(16)
    var bufferIndex = 0
    
    func next(): Unit {
        bufferIndex++
        if (bufferIndex >= prefetchBuffer.size) {
            // 批量预取下一批数据
            prefetchNextBatch()
            bufferIndex = 0
        }
    }
    
    func prefetchNextBatch(): Unit {
        // 一次解析 16 个 item
    }
}
```

**预期收益：** 提升 20-30% 的迭代速度

### Task 9: 优化验证

**验证步骤：**
1. 运行优化前的 Benchmark 记录基线
2. 应用优化
3. 运行优化后的 Benchmark
4. 对比结果，确保性能提升且无功能回归

**验证命令：**
```bash
# 运行所有 benchmark
cjpm bench

# 生成 HTML 报告
cjpm bench --report-format=html

# 导出 CSV 进行对比
cjpm bench --report-format=csv-raw > baseline.csv
# 应用优化后
cjpm bench --report-format=csv-raw > optimized.csv
```

---

## Week 4: 性能对比与文档

### Task 10: Go BadgerDB 对比测试

**对比维度：**
1. **单操作延迟** - 读取、写入、删除
2. **批量操作吞吐量** - 连续写入、范围扫描
3. **并发性能** - 多线程扩展性
4. **内存使用** - Arena 分配效率

**测试方法：**
1. 在相同硬件上运行 Go BadgerDB 的 benchmark
2. 记录结果并与仓颉版本对比
3. 分析差异原因（编译器优化、运行时差异等）

**预期结果：**
- 仓颉版本应该达到 Go 版本的 50-80% 性能（考虑运行时差异）
- 某些操作可能更快（更少的 GC 压力）
- 某些操作可能更慢（编译器优化不如 Go）

### Task 11: 性能文档

**文档内容：**
1. **Benchmark 使用指南** - 如何运行和理解基准测试
2. **性能调优指南** - 如何优化 badger-cj 配置
3. **性能对比报告** - 与 Go BadgerDB 的对比结果
4. **已知限制** - 当前版本的性能瓶颈和解决方案

**文件：**
- `docs/benchmark-guide.md` - Benchmark 使用指南
- `docs/performance-tuning.md` - 性能调优指南
- `docs/performance-report.md` - 性能对比报告

---

## 验收标准

### 功能验收

- ✅ 所有现有测试仍然通过（126/126）
- ✅ 新增 Benchmark 测试至少 10 个
- ✅ Benchmark 测试覆盖核心操作（读写、事务、迭代、并发）

### 性能验收

- ✅ 单次写入延迟 < 10µs
- ✅ 单次读取延迟 < 5µs
- ✅ 范围扫描（1000键） < 1ms
- ✅ 事务提交（10键，无冲突） < 50µs
- ✅ 并发写入吞吐量 > 1000 op/s（10 线程）

### 文档验收

- ✅ Benchmark 使用指南完成
- ✅ 性能调优指南完成
- ✅ 性能对比报告完成

---

## 风险与缓解

### 风险 1: 性能目标过于激进

**影响：** 可能无法达到 Go BadgerDB 的性能水平

**缓解：**
- 调整性能目标到合理的范围（50-80%）
- 重点关注相对性能提升，而非绝对值
- 记录性能瓶颈，为后续优化提供方向

### 风险 2: 优化引入 Bug

**影响：** 优化可能破坏现有功能

**缓解：**
- 每次优化后运行完整的测试套件
- 使用 `@Assert` 验证优化前后的结果一致性
- 渐进式优化，一次只改一个地方

### 风险 3: Benchmark 不稳定

**影响：** 测试结果方差过大，难以得出结论

**缓解：**
- 使用仓颉框架提供的预热和统计分析
- 禁用后台任务，减少噪音
- 增加测试次数，提高统计显著性

---

## 依赖

### 外部依赖

- ✅ 仓颉标准库（`std.unittest`）- 已内置 Benchmark 支持
- ✅ 仓颉编译器（`cjpm bench` 命令）
- ✅ gnuplot（可选，用于生成 HTML 报告）

### 内部依赖

- ✅ Phase 1-4 所有模块已完成
- ✅ 测试基础设施已完善

---

## 时间线

| 周次 | 任务 | 交付物 |
|------|------|--------|
| Week 1 | Benchmark 框架 | 测试文件、数据生成器 |
| Week 2 | 核心基准 | Benchmark 测试套件 |
| Week 3 | 性能优化 | 优化补丁、性能对比 |
| Week 4 | 对比与文档 | 性能报告、使用指南 |

**总工期：** 4 周

---

## 成功指标

1. ✅ **测试覆盖** - 新增 10+ Benchmark 测试
2. ✅ **性能提升** - 关键操作性能提升 20-50%
3. ✅ **文档完善** - 3 份性能相关文档
4. ✅ **对比验证** - 与 Go BadgerDB 性能对比完成

---

## 后续工作（Phase 6+）

Phase 5 完成后，可以考虑：

1. **Compaction 优化** - 后台压缩性能
2. **持久化优化** - SSTable 写入/读取性能
3. **内存管理优化** - 更高效的 Arena 实现
4. **分布式支持** - 多节点扩展性
