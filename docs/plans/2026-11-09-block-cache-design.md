# Block Cache（块缓存）子设计

> 状态：**已实现（2.1.0）**；父项：docs/plans/2026-11-09-v2.1-plus-design.md 的 P1-1 / R4。
> 目标版本：2.1。前置：2.0.1 已发布（arena 对齐 go、.sst 回收）。
> 一句话：给 Table 读路径加一层可配容量的块 LRU，让 mmap 模式的随机读回到「整表驻留堆」
> 的水平，同时保持「内存上界与数据量解耦」这个 2.0 的核心收益。

## 1. 证据（为什么非压缩也值得做）

2.0 的 mmap 模式按需映射：每次 get 读一个 block 都要 MmapFile.read -> memcpy + 新数组
（GC 分配）。堆内模式（MemoryTableData）的 block 切片走 COW 共享，几乎零成本。

实测（sst_read_mem_perf，A/B 交替 5 轮、真实盘、12gb 堆）：

| 数据集 | mmap:on | mmap:off（整表驻留堆） | 比值 |
|---|---|---|---|
| 128MB 随机读 | 112.3 µs/Get | 35.5 µs/Get | mmap 慢 3.2x |
| 16MB 随机读 | 20.8 µs/Get | 7.6 µs/Get | mmap 慢 2.7x |

注意对照口径：v1.6.x 两种模式都是整表预读（35.2 vs 35.2 µs，零差异），所以这不是
「2.0 比 1.6 慢」，而是 2.0 用读延迟换了内存上界（这正是 chronomem OOM 的解法）。
块缓存的作用是把这个代价收回来，且容量可控。

## 2. 设计

### 2.1 位置与键

- 缓存放在 **Table 层之上、TableData 之下**：命中返回 block 字节（Array<Byte>），
  未命中走原有 readBlock 再塞入缓存。
- 缓存键必须包含表身份，否则 compaction 替换后同 blockIdx 会读到旧内容：
  key = (tableId: UInt64, blockIdx: Int64)。tableId 由 Table 持有（compaction 后新表新 id），
  旧表摘除时其缓存条目**主动清除**（见 2.3），不依赖 LRU 自然淘汰。

### 2.2 容量与淘汰

- 新 Config 项：BlockCacheSizeMB（UInt64，默认 0 = 关闭；建议生产 64-256）。
- 关闭时行为与 2.0.1 完全一致（零改动路径）。
- 淘汰：LRU（双向链表 + HashMap），按「条目字节数」计总量，超过上限即从尾部淘汰；
  单条上限 = 1 block（默认 4KB，压缩/加密时按解压后大小计）。
- 不做分片锁（2.1 先单 Mutex；block 命中路径 < 100ns 级，先用基准证明瓶颈再分片——
  避免过早复杂化）。

### 2.3 生命周期

- 摘表（compaction 替换、close）时对该 tableId 的所有缓存条目做失效；
  实现：缓存按 tableId 分桶计数，摘表时遍历 LRU 链删除（表数少、条目数以千计，可接受），
  或额外维护 HashMap<tableId, HashSet<blockIdx>>。
- 建议选后者：摘表是低频操作，桶索引让失效 O(该表条目数)。
- Windows 约定不变：先 close 映射再 unlink；缓存只持有内存字节，不持有映射。

### 2.4 与压缩/加密的关系

- 2.0 默认 Compression=None，缓存的是磁盘原始 block 字节；开启压缩/加密后应缓存
  **解压/解密后**的 block（否则每次命中仍要解压），容量按解压后大小计。
- 与 R4 决策一致：缓存一律可开，不限压缩路径。

## 3. 验收

1. 相同场景（128MB / 16MB 随机读）mmap 模式读延迟 **回到堆内模式的 1.1x 以内**；
2. 关闭缓存（默认 0）时全量测试与 2.0.1 完全一致（行为零变化）；
3. 内存上界：RSS 增量约等于 BlockCacheSizeMB + 元数据（给出实测曲线）；
4. compaction 后读新表数据正确（缓存失效用例：压缩替换前后同 blockIdx 不同内容）；
5. 并发 get 无数据竞争（-j 4 全量 + 并发读用例）；
6. 全量测试绿（当前 455 例基础上新增缓存相关用例）。

## 4. 实施步骤（TDD）

1. 先写失败用例：缓存命中计数（命中第二次 get 不应再触发 readBlock）、失效用例
   （compaction 后旧 blockIdx 内容不得复活）、容量淘汰（超过上限后最旧条目被逐出）；
2. 实现 Config.BlockCacheSizeMB + BlockCache（Put/Get/InvalidateTable/Close）；
3. 接到 Table.readBlock 与摘表路径；默认关闭，测试里显式开；
4. 基准：sst_read_mem_perf 128MB/16MB，mmap:on + cache=0/64/256 对照（A/B 交替）；
5. 文档：benchmark-report 增补、2.1 总账 P1-1 状态更新、README 配置项。

## 5. 风险

| 风险 | 对策 |
|---|---|
| 缓存让「内存上界」重新变模糊 | 容量显式配置、默认 0；文档写清「缓存上限 + 元数据」 |
| 摘表失效遗漏 -> 读到旧表数据 | 失效用例钉住；tableId 进 key，命中前校验 tableId 存在性 |
| 单锁竞争 | 先基准；若命中路径占比高再分片（2.2 明确「先证明再拆」） |
| 大 block（压缩后单块 > 4KB）膨胀 | 单条按实际大小计费，超上限的大块可只走直读不入缓存 |

## 6. 实现结果（2026-11-09）

- 代码：src/table/block_cache.cj（按字节 LRU、键 (tableId, blockIdx)、摘表即失效）；
  Table.readBlock 命中直返、未命中读盘后写入；Config.BlockCacheSizeMB（默认 0）；
  已接入 loadTables / flush 落盘 / compaction 产出三条建表路径。
- 测试：BlockCacheTest 4 例（命中计数 / LRU 顺序 / 按表失效 / 容量 0）+ BlockCacheDbTest 2 例；
  全量 461/461（-j 4，连跑 2 轮绿）。
- 实测（128MB 随机读）：cache=0 113.2 µs/Get → cache=64MB **36.9 µs/Get**（堆内 35.9 µs，
  **1.03x**，验收目标 1.1x 达成）。

## 7. 后续

- 默认值建议：0 保持默认（行为兼容）；生产建议 64-256MB，文档给建议值。
- P2-1 Stats API 可把 hits/misses/used 暴露出去（BlockCache 已内置计数）。
