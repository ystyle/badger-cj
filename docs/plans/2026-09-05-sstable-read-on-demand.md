# Badger-cj v2.0：SSTable 读按需化（表数据移出 GC 堆）

> 状态：已实现（阶段 A–D，v2.0.0；`feat/v2-mmap-wal-vlog` @ ab6f640）
> 目标版本：v2.0.0（与 `2026-09-01-mmap-wal-vlog-design.md` 的 mmap 基础设施线并行/同批）
> 口径（2026-11-09 更新）：本设计只对齐 go 的语义、**不追求文件格式字节兼容**；加密不进 2.0；
> 常规 flush 路径接入映射（B1）、`Iterator` allVersions 吐 tombstone（B4）、lazy index 等收尾项见
> [`2026-11-09-v2.0-implementation-plan.md`](2026-11-09-v2.0-implementation-plan.md)。
> 来源：chronomem 生产验证（2026-09-05）——稳态堆活随数据线性涨 + 大请求瞬时峰值，
> 与 256MB 堆上限结构性矛盾 → 周期性 OOM（修复后已降级为「单请求牺牲 + 服务自愈」，
> 但结构性矛盾仍在）
> 关联：`mmap-cj`（三平台 mmap 封装）、go 版 `Table`（mmap 打开 + refcount）、
> v1.6.17 L1 TableBuilder 单拷贝（构建产物即常驻 data 的唯一来源，按需化后该驻留取消）

## 1. 背景与动机

### 1.1 稳态内存随数据线性涨的根因

当前表数据生命周期（磁盘模式）：

```
flush/compaction/loadTables → File.readFrom 全量读入 → Table.data: Array<Byte>（GC 堆）
  → 读路径 readBlock 从 data 切片 → compaction 合并后旧表引用释放（GC）→ 表文件删除
```

- 表数据（含 L0 全部 + L1+ 已 compact 表）**整表常驻 GC 堆**，直到被 compaction 合并或 close；
- GC 堆内的数据**不可被 OS 回收**——堆上限（默认 256MB）与「驻留随库数据量涨」构成
  结构性矛盾：数据量持续增长 ⇒ 必然周期性 OOM（与请求大小无关，只是大请求提前撞顶）；
- v1.6.17 已验证把 OOM 从「协程持锁死/整机脏卡」降级为「单请求牺牲 + 服务自愈」、
  丢数据窗口清零——但**周期 OOM 本身仍在**（chronomem：每 ~7-8 条 950KB 请求一次）。

### 1.2 go 对照：数据在页缓存，不在 GC 堆

go badger 的 `Table` 用 `z.MmapFile` 打开（table.go OpenTable），表数据是**文件映射**：

| 维度 | go badger | badger-cj 现状 |
|------|-----------|----------------|
| 表数据存放 | mmap（页缓存，OS 可驱逐） | GC 堆 `Array<Byte>`（不可回收） |
| 内存压力行为 | 页缓存被回收 → 读性能波动 | 堆满 → **OOM** |
| 表生命周期 | 映射 + refcount，compaction 后 Close | 无句柄、无释放，纯 GC |
| 大表/多表 | 虚拟内存大、物理页按访问加载 | 全量物理驻留 |

**本质收益**：把表数据从「不可回收的 GC 堆」搬到「可回收的页缓存」——OOM 退化为
性能波动。这不是「内存不随数据涨」（物理 RSS 仍近似活跃访问集），而是**消除堆与
数据量的结构性矛盾**。

### 1.3 chronomem 现场证据

- 限长（拒绝 >256KB 条目）+ 调堆（256MB→1GB）是**容量侧缓解**（治标，随数据增长复发）；
- 按需化是**结构侧根治**：稳态堆 = 元数据 + memtable（背压有界），与数据总量解耦。

## 2. 目标与非目标

### 2.1 目标

1. 磁盘模式表数据**移出 GC 堆**：打开时映射（或按需读），读路径从映射/文件取块，
   物理页由 OS 按访问加载、可回收；
2. flush/compaction 产出的新表同样走映射——**构建产物不再以常驻 data 形式保留**
   （v1.6.17 L1 后 data 是构建产物唯一去向，按需化后写盘完成即可弃）；
3. 表生命周期显式化（refcount + 关闭），compaction 替换表后立即释放；
4. 读语义、文件格式、API **零变化**（361 测试回归网原样通过）。

### 2.2 非目标

- InMemory 模式不动（本就是内存库，`addMemoryTable` 语义保留）；
- 不做 Block/Index Cache（属 v2.2 独立项，本设计只解决数据存放层）；
- 不改变 SSTable 写路径形态（io_uring 保持，v2.0 只加 WAL/VLog mmap 写）；
- 不承诺 RSS 不随数据涨（那是页缓存语义，物理占用取决于访问模式）。

## 3. 现状分析（读路径数据流）

```
Table.data: Array<Byte>          ← flush/compaction 构建产物 / loadTables 全量读盘
TableIndex.decodeFromData(data)  ← index/bloom 解析（每表一次，小）
readBlock(idx): data[offset..offset+len]  ← 每读一个 block 切一段（当前即拷贝）
TableIterator / TableAdapter.get ← 上层读全部经 readBlock
```

- 表文件**不可变**（写盘后不再改动）——映射安全，无一致性窗口；
- 读放大点：`data[...]` 切片（仓颉切片复制整块）——映射后可直接取映射内切片或
  仍复制（页缓存命中下复制开销远小于 syscall，语义不变）；
- 表无文件句柄持有：loadTables 读完全量即关文件——按需化后需**长期持有句柄/映射**，
  生命周期管理是本次改造的核心新增。

## 4. 形态选型

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| A. mmap 只读映射（mmap-cj） | 零拷贝、页缓存按需、unlink 后映射存活（compaction 删文件与读者并发安全）、与 v2.0 WAL/VLog mmap 同技术栈（mmap-cj 已三平台发布） | 需长期持有映射（虚拟地址占用）；Windows 删除被映射文件受限（先解除映射） | **首选** |
| B. File 句柄 + seek/read + 块缓存 | 无 FFI、无映射生命周期 | 每块 syscall（页缓存命中 ~µs 级，需 LRU 块缓存补偿）；compaction 删文件与并发读需句柄引用计数 | 备选（若 mmap-cj 缺口） |

选 A，理由：与 v2.0 同栈（基础设施一次投入）、**unlink 语义天然解决「compaction 删旧表
文件 vs 读者/迭代器并发」的生命周期难题**（映射持有者不受文件删除影响，解除映射由
refcount 控制）；mmap-cj 已提供 linux/darwin/windows 封装（2026-09-01 设计 1.4 已论证）。

## 5. 设计

### 5.1 Table 数据源抽象

```
interface TableData {                    // 新增内部抽象（table 包内）
    readBlock(offset, len): Array<Byte>  // 返回块字节（复制语义，与现状一致）
    close(): Unit                        // 释放映射/句柄
}
- MemoryTableData(data)   ← InMemory 模式 / 测试（现状 Array<Byte> 语义）
- MmapTableData(path)     ← 磁盘模式：mmap-cj 只读映射 + 惰性页
```

- `Table` 持有 `TableData` 而非裸 data；`TableIndex` 解析所需数据（index/bloom 在文件
  尾部）在映射建立后直接从映射读取（无需全量读盘）；
- 上层（TableAdapter/迭代器/compaction）零改动。

### 5.2 生命周期与引用计数

- 表映射生命周期 = 表在 LevelHandler 中的存活期 + 在途读者/迭代器持有期；
- 引入 `Table` refcount：get/迭代器创建时 incr，释放时 decr，归零 close（解除映射）；
  compaction 从 LevelHandler 摘表后 decr——**unlink 先于 close 也安全**（映射存活到
  最后一个持有者）；
- 现状「无句柄、纯 GC」的简洁性代价：需要正确关闭所有迭代路径（TableIterator、
  TableIterWrapper、MergeIterator 链、vlog GC 读表等）——逐点审计，漏关 = 映射泄漏
  （虚拟地址，不 OOM 但需防）；
- 替代简化：映射只随表进出 LevelHandler（表不可变，迭代器短暂持有期间文件被
  compaction unlink 不影响映射有效性）——**若全路径都经 LevelHandler 表集合取块，
  可免 refcount**，用「LevelHandler 摘表时统一 close（此时无并发读者持有表引用——
  读者在 LevelHandler 锁内取表后读块，块复制已脱离表）」。读块即复制 ⇒ 读不跨表
  存活 ⇒ 摘表即 close 安全。**设计倾向免 refcount 方案**，实施时以审计结论定。

### 5.3 写路径联动（flush / compaction / 恢复）

```
现状（v1.6.17 L1 后）：构建 data → 写盘 → addTable(Table(data))，data 双用途（落盘 + 常驻）
目标：
  flush/compaction: 构建 data → writeFile 落盘（io_uring/同步，不变）
                     → TableData = MmapTableData(path)（映射文件，构建 data 即可弃）
                     → addTable；构建期峰值内存因此再降一档（无整表常驻副本）
  恢复(loadTables): 映射而非 File.readFrom
  表文件删除（compaction 完成 / 孤儿清理）：先 unlink（映射不受影响），
                    LevelHandler 摘表后 close 映射
```

- MANIFEST/崩溃恢复语义不变（表文件仍以 Create/Delete 记录；文件完整性与 checksum
  读侧校验维持现状——注意 crc-cj -O2 疑点另案，启用校验前先修）；
- **Windows 注意**：被映射文件不能删除 → 摘表后先 close 映射再 unlink（平台分支）。

### 5.4 读性能预期

- get/迭代：映射页缓存命中 = 现内存切片同量级（多一次页表访问，可忽略）；未命中 =
  一次缺页（等价现冷数据读盘）；
- compaction 输入全表顺序读：页缓存友好，等价现全量读入但**不再常驻**；
- L0 高频随机小块读：工作集内页缓存命中，物理占用 ≈ 活跃 L0 数据量。

## 6. 平台与测试策略

### 6.1 平台矩阵

| 平台 | mmap 只读映射 | unlink+映射存活 | 摘表后 close+unlink 顺序 |
|------|--------------|----------------|--------------------------|
| Linux | ✅ | ✅（POSIX） | 任意顺序均可 |
| macOS | ✅（mmap-cj） | ✅（POSIX） | 任意顺序均可 |
| Windows | ✅（CreateFileMappingW） | ❌（需先解除映射） | **必须先 close 后 unlink** |

### 6.2 测试清单

1. **双模式等价**：同一 .sst 经 MemoryTableData 与 MmapTableData 读回逐 key 一致
   （golden 指纹思路复用：指纹 + Table 读回双重锚）；
2. flush/compaction 落盘新表走映射：现有 361 测试原样通过即回归网；
3. 生命周期：compaction 替换表后映射释放（迭代器/读经摘表后 close 的并发用例）；
4. 恢复路径：close→reopen、崩溃重开（现有 crash/persist 测试族）；
5. 平台：Linux 全量；macOS/Windows 由三平台 CI（v2.0 阶段 5）覆盖关键用例；
6. 性能：flush_impact 专项 + DB Get 延迟（对比 v1.6.17 基线，禁止回退）。

## 7. 实施阶段（并入 v2.0 排期）

| 阶段 | 内容 | 验收 |
|------|------|------|
| A | TableData 抽象 + MemoryTableData 提取（纯重构，行为零变化） | 361 全绿 |
| B | MmapTableData + flush/compaction/loadTables 接入映射 | 等价测试 + 361 全绿 |
| C | 生命周期审计与收口（摘表 close / Windows 顺序） | 并发/恢复测试 |
| D | 性能复测 + 内存对照（chronomem 场景堆曲线） | benchmark-report 更新 |

> 依赖：mmap-cj 只读映射 API（含文件大小/长度查询）确认；与 WAL/VLog mmap 化
> （2026-09-01 文档）共用 mmap-cj，实施顺序可在阶段 1（WAL/VLog）后或并行。

## 8. 风险与回退

| 风险 | 对策 |
|------|------|
| 映射生命周期漏关（虚拟地址泄漏） | 免 refcount 方案（读块即复制、摘表即 close）优先；审计全部迭代路径 |
| Windows 删除被映射文件受限 | 平台分支：先 close 映射再 unlink；三平台 CI 覆盖 |
| 读路径性能回退（缺页/切片） | 页缓存命中为主；benchmark 基线对照（v1.6.17），回退可保留 Config 开关走内存模式 |
| 与 v2.2 Block/Index Cache 重叠 | 本设计只管数据存放层；缓存是上层独立项 |
| mmap-cj 能力缺口 | 需只读映射 + 长度查询；缺口则回退方案 B（File+块缓存） |

## 9. 相关文档

- `docs/plans/2026-09-01-mmap-wal-vlog-design.md`（v2.0 WAL/VLog mmap 写路径，同技术栈）
- `docs/plans/2026-09-05-async-flusher-l1-builder-design.md`（v1.6.17，flush 架构与 L1 单拷贝）
- `docs/benchmark-report.md`（性能基线 v7.0）
- go 版：`~/Projects/badger/table/table.go`（OpenTable / MmapFile + refcount）
- chronomem 验证报告（2026-09-05，OOM 结构性矛盾现场证据）
