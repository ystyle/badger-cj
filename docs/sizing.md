# 容量规划与调参：cjHeapSize / memTableSize / numMemtables

> 面向部署者。读这一篇能回答三个问题：**我要给多少堆**、**memtable 开多大**、**默认配置为什么会在低堆下炸**。
> 结论都来自实测（`docs/benchmark-report.md` §2.2、`scripts/bench/heap-sweep.py`），不是估算。

## 0. 先记住三句

1. **仓颉的 GC 堆是有硬上限的**（`cjHeapSize`，默认 256MB），超了就是 `OutOfMemoryError`，运行时不会像 Go 那样按机器内存自己放。
2. **memtable arena 就落在 GC 堆里**（底层是 `Array<Byte>`），每张表约 `1.32 × memTableSize`，在途表最多 `numMemtables + 1` 张 → 这是堆里最大的单项。
3. **表越大越贵，且不是线性感觉上的贵**：4MB 表 48MB 堆能跑，16MB 表要 192~256MB，64MB 表要 768MB 起（见 §3 实测表）。低堆部署优先「小表 + 流式落盘」。

## 1. 内存都花在哪

| 区域 | 归属 | 计入 `cjHeapSize`？ | 随什么增长 |
|---|---|---|---|
| memtable arena | GC 堆 | **是** | `1.32 × memTableSize × (1 + numMemtables)` |
| skiplist 节点索引（`AtomicStorage`） | GC 堆 | **是** | 条目数（值越小，单条开销占比越大） |
| flush/compaction 建表临时对象 | GC 堆 | **是** | 整表字节模式 ≈ `2~3 × 表大小`；流式落盘 ≈ 单块 4KB + 索引 |
| Block Cache（`blockCacheSizeMB`） | GC 堆 | **是** | 容量上限本身 |
| 写管道编码缓冲 | GC 堆 | **是** | 单批条目字节（≈ 批大小 × 值大小） |
| 迭代器持有的 block 副本 | GC 堆 | **是** | 活跃迭代器数 × block |
| WAL | 原生 mmap | 否 | 每段 `2 × memTableSize`（稀疏预分配，按写入 touch） |
| VLog | 原生 mmap | 否 | `vlogFileSize`（默认 1GB/段） |
| SSTable 读取 | 原生 mmap | 否 | 页缓存（内核管理） |

所以：**堆上限要按 arena 来定，容器内存要按「堆 + mmap」来定**。

## 2. 下限公式（必要不充分）

```text
cjHeapSize ≥ 32MB                       # 运行时基线（实测 open 后 RSS ≈ 25MB）
           + 1.32 × memTableSize × (1 + numMemtables)   # arena
           + blockCacheSizeMB
           + 单批条目字节 ≈ 批大小 × 值大小
           + flush 额外：流式 ≈ 0.5 × memTableSize；整表字节 ≈ 2.5 × memTableSize
```

这个公式给的是**下限**：

- `memTableSize=4MB, numMemtables=2, 流式` → 32 + 15.8 + 2 ≈ 50MB，实测最小 48MB ✅；
- `memTableSize=16MB, numMemtables=5, 流式` → 32 + 106 + 8 ≈ 146MB，实测最小 192MB（**公式偏低**）。

规律：**`memTableSize ≤ 4MB` 时公式很准；越大越要按实测表并留 1.3 倍余量**——大块 GC 数组需要更多
堆余量，GC 才追得上分配速度。

## 3. 实测：最小可用堆（真实盘、`cjHeapSize` 扫描）

负载：1KB 值、每事务 100 条、写入量 = 2 × memTableSize；「通过」= 进程正常结束且数据完整。
堆候选按档位扫（32/48/64/96/128/192/256/384/512/768/1024MB），相邻档位有 ±1 档噪声。

| memTableSize | numMemtables | 流式落盘（默认建议开） | 整表字节（默认关时） |
|---|---|---|---|
| 1MB | 2 | 32MB | — |
| 4MB | 2 | **48MB** | 96MB |
| 16MB | 2 | **192~256MB** | 256MB |
| 64MB | 2 | **768MB** | 1024MB |
| 4MB | 5 | 48MB | — |
| 16MB | 5 | 192MB | — |
| 64MB | 5 | 768MB | — |

注意两件事：

1. **整表字节模式在 4MB 档位要多一倍堆**（96 vs 48MB）——那份「整表副本」是实打实的堆占用；
   表越大，两边都被 arena 支配，差距才显得小。
2. 低堆下的失败形态有两种：**`OutOfMemoryError`**（直接）和**长时间卡住**（flush 反复重试、写路径等腾位）。
   后者看起来像"慢"，其实是堆已经在临界点——不要当成性能问题去调 `memTableSize` 以外的参数。

## 4. 预算 → 推荐配置

| 可给 cjHeapSize | 推荐 memTableSize | 推荐 numMemtables | 备注 |
|---|---|---|---|
| 64MB | 1~2MB | 2 | 嵌入式/多库/CI，单库只占几十 MB |
| 128MB | 4MB | 2~3 | 忆时塔生产就是这一档（4MB 表） |
| 256MB（仓颉默认） | 8~16MB | 2~3 | **默认 64MB 表在这里跑不动**，见 §5 |
| 512MB | 16~32MB | 2~3 | |
| 1GB | 32~64MB | 2~3 | 默认 64MB 表 + 流式在此可跑 |
| 2GB+ | 64MB（默认） | 5（默认） | 默认配置的舒适区 |

同时打开流式落盘（`Config(streamingSSTable: true)`）能把同一份堆下的可用表大小抬一档，
并把 compaction 的峰值 RSS 降 3 倍以上（415MB → 120MB，见 benchmark-report §2.2）。

## 5. 为什么默认配置在默认堆下会炸

库默认 `memTableSize=64MB`、`numMemtables=5`；仓颉默认 `cjHeapSize=256MB`。两者不是一组：

- arena 上限 = `1.32 × 64MB × 6 ≈ 422MB` —— 已经超过 256MB 堆；
- 实测：64MB 表在流式下要 **768MB** 堆、整表字节下要 **1024MB**。

所以在默认堆下用默认表大小，写入到第一次大 flush 就会 OOM（或卡死）。三条路选一：

1. **给够堆**：`cjHeapSize=1GB`（推荐 ≥1GB 再配 64MB 表）；这是默认配置的舒适区。
2. **调小表**：`memTableSize=8~16MB` 配 `numMemtables=2~3`（256MB 堆可用）。
3. **开流式落盘**：同堆下能跑更大的表、峰值显著更低，但不改变 arena 的固定占用。

### 5.1 渐进扩容（2.2，默认开）省的是「起步占用」

`arenaGrowthStartBytes`（默认 256KB）让第一张 memtable 从小 arena 起步、每轮翻倍、封顶目标值。

| 配置（memTableSize=64MB） | open 后 RSS | 首张 memtable arena |
|---|---|---|
| 默认 256KB 起点 | **25.2MB** | 256KB |
| `arenaGrowthStartBytes=0`（关闭渐进） | 57.8MB | 86.2MB |

所以「打开库就吃几十上百 MB」的场景（嵌入式、多库、CI）收益明显；它省的是起步占用，稳态仍按 §2 的公式算。
单条条目大于当前 arena 时写路径会按需抬升，不会因为起点小而写不进大 value。

## 6. 怎么设堆（进程级）

```shell
# 直接跑
export cjHeapSize=1GB      # 堆上限
export cjGCThreshold=768MB # 触发 GC 的阈值（一般取堆的 70~80%）
export cjGCInterval=100ms  # GC 轮询间隔
export cjBackupGCInterval=200ms
```

```dockerfile
# Dockerfile
ENV cjHeapSize=1GB \
    cjGCThreshold=768MB \
    cjGCInterval=100ms
```

```yaml
# docker compose / k8s：容器限额要 ≥ 堆 + mmap（WAL/VLog/SST 页缓存）
# 经验：cjHeapSize ≈ 容器内存上限的 60~70%，其余留给页缓存与运行时
environment:
  cjHeapSize: "1GB"
mem_limit: 1536m
```

进程总内存 ≈ `cjHeapSize`（GC 堆）+ WAL/VLog 段（按活跃段算）+ SST 页缓存 + 运行时/二进制。
**容器内存只按 cjHeapSize 设一定会在高负载时被 OOM-kill**（页缓存算在容器 RSS 里）。

## 7. 症状 → 对策

| 症状 | 最可能的原因 | 对策 |
|---|---|---|
| 写入时 `OutOfMemoryError` | 堆 < arena + 建表临时对象 | 调大 `cjHeapSize`，或调小 `memTableSize` |
| 写入/关闭卡很久，最终超时 | 堆在临界点，flush 反复重试 | 同上（别先怀疑磁盘） |
| RSS 高但堆没满 | mmap 页缓存 / Block Cache | `blockCacheSizeMB` 计入堆，mmap 靠内核回收；必要时限制容器页缓存 |
| 打开库就占几十上百 MB | arena 预分配（默认表 64MB） | 调小 `memTableSize`，或依赖渐进扩容（默认 256KB 起步） |
| 关闭慢 | 关闭时要 flush 大表 | 调小表 / 开流式落盘 |

## 8. 与 Go Badger 的差别（为什么这件事在仓颉里更"显式"）

| | Go BadgerDB | badger-cj |
|---|---|---|
| memtable arena | 原生内存（`mmap`/`malloc`），**不占 GC 堆** | `Array<Byte>`，**占 GC 堆** |
| 堆大小 | Go runtime 自动伸缩（可选 `GOGC`/`GOMEMLIMIT`） | `cjHeapSize` 显式上限，默认 256MB，运行时不按机器内存自动调 |
| 用户心智 | 通常无感 | 必须按本指南显式配 |

这是**运行时差异**，不是 badger-cj 单方面能消除的。彻底「无感」需要把 arena 改成原生内存
（FFI 分配 + 手工生命周期），属重构，暂未排期；在那之前请照 §2~§4 配置。

## 9. 复现与自查

```shell
# 真实盘 + 自动二分找最小可用堆（把 DATA 换成非 tmpfs 的目录）
python3 scripts/bench/heap-sweep.py --bisect \
  --bin target/release/bin/badgercj.examples.mem_profile \
  --data-dir /path/on/real/disk --workdir . \
  --heaps 32,48,64,96,128,192,256,384,512,768,1024 --timeout 60 \
  --cases "s-4-2:flush 1 4 2 8 1024 1"    # 流式 / 4MB 表 / nb=2 / 写 8MB
```

线上自查：`db.getStats()` 的 `MemTableArenaBytes`（arena 分配总量）、`MemTableUsedBytes`（已用）、
`MaxBatchBytes`（单批最大预留）；`/proc/<pid>/status` 的 `VmHWM` 是进程峰值 RSS。
