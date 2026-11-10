# 容量规划与调参：cjHeapSize / memTableSize / numMemtables

> 面向部署者。读这一篇能回答三个问题：**我要给多少堆**、**memtable 开多大**、**默认配置为什么会在低堆下炸**。
> 结论都来自实测（`docs/benchmark-report.md` §2.2、`scripts/bench/heap-sweep.py`），不是估算。

## 0. 先记住三句

1. **仓颉的 GC 堆是有硬上限的**（`cjHeapSize`，默认 256MB），超了就是 `OutOfMemoryError`，运行时不会像 Go 那样按机器内存自己放。
2. **memtable arena 就落在 GC 堆里**（底层是 `Array<Byte>`），每张表 = `memTableSize + 批次预留 + 节点项`（小表约 1.32×；2.3 起大表约 1.05~1.07×），在途表最多 `numMemtables + 1` 张 → 这是堆里最大的单项。
3. **表越大越贵，且不是线性感觉上的贵**：4MB 表 48MB 堆能跑，16MB 表要 192~256MB，64MB 表要 768MB 起（见 §3 实测表）。低堆部署优先「小表 + 流式落盘」。

## 1. 内存都花在哪

| 区域 | 归属 | 计入 `cjHeapSize`？ | 随什么增长 |
|---|---|---|---|
| memtable arena | GC 堆 | **是** | 每张 `memTableSize + 预留 + 节点项`，再 × (1 + numMemtables)（见 §2） |
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
           + (memTableSize + min(15%×memTableSize, 2MB) + 节点项) × (1 + numMemtables)  # arena
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

### 3.1 2.3 默认变更后的复测（2026-11-10）

- **流式落盘默认开**（`streamingSSTable` 默认 true）：上表「流式」列就是默认行为；关掉会回落到「整表字节」列（回退手段）。
- **批次预留改为 `min(15% × memTableSize, 2MB)`**：堆边界基本不变（相邻档位本就 ±1 档），但**稳态 arena 占用**显著下降。同一二进制、只改预留的 A/B（mt=64MB、nb=5、写 128MB、12GB 堆）：

| 预留 | arena/表 | 5 张合计 | 峰值 RSS |
|---|---|---|---|
| **2.3 默认（封顶 2MB）** | **68.2MB** | **341MB** | **611MB** |
| 2.2 口径（15% ≈ 9.6MB） | 84.2MB | 421MB | 644MB |

16MB 表：20.2MB vs 21.05MB（-4%），对峰值 RSS 影响 <1MB；4MB 及以下表的预留仍是 15%（未到 2MB 上限），行为不变。单批最大预留实测仍是 28KB~1.65MB（benchmark-report §2.2 P1-4-A），2MB 上限留有 1.2× 以上余量。

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

- arena 上限 = `68.2MB × 6 ≈ 409MB`（2.3 收紧预留后；2.2 是 84.2MB × 6 ≈ 505MB）—— 都超过 256MB 堆；
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
| memtable arena | `make([]byte, n)`（`skl/arena.go`）→ **同样在 GC 堆里** | `Array<Byte>(n)` → **同样在 GC 堆里** |
| Go 侧的 mmap 用在哪 | WAL / VLog / SSTable 读——与 badger-cj 2.0 的范围**一致** | 同 |
| 堆大小 | Go runtime 按需增长（无硬上限，`GOGC`/`GOMEMLIMIT` 只是软约束） | `cjHeapSize` **硬上限**，默认 256MB，超了直接 `OutOfMemoryError` |
| 用户心智 | 通常无感（机器够大就跑得动） | 必须按本指南显式配 |

所以差异**不在「Go 用原生内存、仓颉用 GC 堆」**（两边 memtable 都在各自 GC 堆里），而在
**堆有没有硬上限**：Go 堆会一直涨到机器能给为止，仓颉默认 256MB 顶住就是 OOM。
这也解释了一个反直觉现象：同样的 `memTableSize=64MB × numMemtables=5`（2.3 约 341MB 堆占用，2.2 约 421MB），
Go 版在 16GB 机器上毫无感觉，badger-cj 在默认堆下直接炸。

> 历史记录：2.0 的设计（[`plans/2026-09-01-mmap-wal-vlog-design.md`](./plans/2026-09-01-mmap-wal-vlog-design.md) §3.2）
> 把「arena 内存分配不换 mmap」列为**非目标**——理由是 mmap 的目标就是持久化数据文件，而 arena 是可变运行时结构，
> 给它上文件映射会引入预分配/删除文件、脏页回写、Windows 先 close 后 unlink 等约束，收益对不上；同时 Go 自己也没这么做。
> 当时**没有低堆实测证据**（低堆 OOM 是 2.0 之后由下游现场与 P0-2 测量才暴露的），所以这个决定在当时是对的。

要彻底「无感」，路径不是文件 mmap，而是 **arena 换原生匿名内存**（`malloc` / `mmap(MAP_ANONYMOUS)`）：
不占 GC 堆、可被 OS 换页、没有文件生命周期。仓颉有 FFI（本仓 `io_uring` 已在用 `LibC.malloc`），技术上可行；
代价是手工生命周期与跨平台 FFI，属重构，暂未排期。按最新实测，它的收益是「把 memtable 从堆里整块摘掉」
（默认配置 420MB 堆占用 → 0），比 §5 的「预留收紧」（省 12%~21%）彻底得多。


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
## 10. 后续方向：arena 原生化，以及「编译期开关」怎么选

### 10.1 不要用 cjpm 的 source-set / features

已在 **mmap-cj** 上实测并回退（第一手证据，不是文档推理）：

- `fcb774e` 把 mmap-cj 重构成 source-set 跨平台结构（三个平台各一个源码集），自身构建/测试能过；
- `698e673` 又**回退**为「单 src + `@When` 条件编译」。commit 原文给的原因：
  source-set 是 cjpm 的 **experimental** 特性，**消费者必须同样声明 `[profile] experimental = true`**
  才能编译本库，否则直接报 `path of src directory 'src' ... does not exist`；而该特性正式发布尚需时间；
- v1.1.0（`cc40de1`）起固定为单 src + `@When`：SDK 自带 cjpm 即可构建，macOS/Windows CI 双绿。

对 badger-cj 的推论：我们的库是给下游用的，**不能要求每个消费方打开 experimental**——这条路直接排除。

### 10.2 平台差异用 `@When`，用户可选走 `Config`

| 切分维度 | 机制 | 成本 |
|---|---|---|
| **OS/架构**（Linux `mmap(MAP_ANONYMOUS)` vs Windows `VirtualAlloc`） | `@When[os == ...]`（内置条件） | 零配置、消费方无感；mmap-cj 已验证 |
| **用户选择**（要不要用原生 arena） | 运行时 `Config.arenaBackend` | 一份二进制、CI 一条矩阵 |
| 用户选择（误用编译期 cfg） | `@When[自定义cfg]` | 未定义=编译错误；库定义后消费方无法覆盖（`user defined condition's key can not repeat`）；只能全局一份值 |

**推荐形态**：编译期只处理平台差异（`@When`），运行期用一个 `Config.arenaBackend` 决定是否启用原生 arena。

### 10.3 收益、代价与优先级

- **收益**：默认配置（64MB × 5 张）arena 约 341MB 堆占用（2.2 口径 421MB）→ 0；而生产 OOM 的本质正是
  「堆上限 256MB、live 只有 30~60MB、峰值却没余量」（忆时塔 `library/570` 记录）。
- **代价**：手工生命周期 + 跨平台 FFI；越界从「抛数组越界异常」变成「进程崩溃」，需要专门的边界/模糊用例与
  ASan 类验证；GC 不再追踪这块内存（arena 里只放纯字节，前提已满足）。
- **优先级**：2.3.0 先做低风险两件（流式落盘翻默认、预留收紧），arena 原生化单独一轮（2.4）。

