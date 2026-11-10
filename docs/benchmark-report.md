# Badger-cj 性能基准测试报告

**测试日期：** 2026-10-10
**被测版本：** v1.6.21（commit `d9bf136`，中心仓已发布）
**测试环境：** Linux x86_64 · AMD Ryzen 7 7840HS（16 核）· 29 GiB 内存 · 内核 7.2.6
**仓颉编译器：** cjc 1.1.3 (cjnative)，`-O2`，`cjHeapSize=12gb`
**数据目录：** btrfs 真实盘（**非** tmpfs）· 每项连跑 5 轮取中位数

> **测量方法见 [`benchmark-methodology.md`](benchmark-methodology.md)。**
> 本报告只包含两类数据：① 当前 revision 的绝对值；② 同一二进制内的开关对照。
> **不做跨版本对比**（原因见方法学 §2.1）。
> 可复现入口：`python3 scripts/bench/run-bench.py --runs 5`

---

## 0. 读数前必看：哪些数字可信

| 标记 | 含义 |
|---|---|
| ✅ | 离散度 ≤ 15%，点值可引用 |
| ⚠️ | 离散度 > 15%，**只宜作定性描述**，不可引用点值 |

历史报告中那些精确到个位数的 ns/op 大多属于 ⚠️ 一类。
典型例子：`skiplist_perf` 全部 4 项总耗时仅约 **64ms**，30 轮复测的并发写中位数
387 ns/op、**离散度 ±39.8%**（范围 352–506）。在这个负载规模下，
"330"与"380"没有统计差异。

---

## 1. 环境指纹

| 项 | 值 |
|---|---|
| commit | `d9bf136`（tag `v1.6.21`） |
| 版本 | 1.6.21 |
| cjc / cjpm | 1.1.3 (cjnative) / 1.1.3 |
| CPU | AMD Ryzen 7 7840HS w/ Radeon 780M Graphics |
| 核数 | 16 |
| 内存 | 29 GiB |
| 内核 | 7.2.6-arch2-1 |
| 数据目录文件系统 | **btrfs**（真实盘） |
| 运行约定 | `cjHeapSize=12gb`、`-j 16`、每项 5 轮取中位数 |

> ⚠️ 所有 `src/examples/*_perf` 都把数据目录**硬编码为 `/tmp`**（共 9 处）。
> 本机 `/tmp` 是 **tmpfs**。为在不改动被测源码的前提下取得真实 I/O 数字，
> 测量时用 `unshare -rm` + `mount --bind` 把数据目录重定向到 btrfs。
> 详见方法学 §一 缺陷 1。

---

## 2. Skiplist（5000 ops / 16 线程）

来源：`badgercj.examples.skiplist_perf`（30 轮）

| 指标 | 中位数 | 离散度 | 范围 |
|---|---|---|---|
| 并发写 (ns/op) | 387 | ⚠️ ±39.8% | 352 – 506 |
| 并发写吞吐 (ops/sec) | 2,581,370 | ⚠️ ±33.4% | 1,974,520 – 2,835,701 |
| 并发读 (ns/op) | 332.5 | ⚠️ ±39.1% | 256 – 386 |
| 并发读吞吐 (ops/sec) | 3,003,479 | ⚠️ ±43.4% | 2,590,324 – 3,893,147 |
| 顺序写 (ns/op) | 554.5 | ⚠️ ±39.1% | 519 – 736 |
| 顺序写吞吐 (ops/sec) | 1,802,082 | ⚠️ ±31.5% | 1,356,876 – 1,924,595 |
| 顺序读 (ns/op) | 1,227 | ⚠️ ±27.1% | 1,110 – 1,442 |
| 顺序读吞吐 (ops/sec) | 814,430 | ⚠️ ±25.4% | 693,085 – 900,208 |

**结论：** 并发写中位数约 **390 ns/op**、并发读约 **330 ns/op**，
并发吞吐约 **260 万次/秒**。**但两项离散度都在 ±40% 量级** —— 该基准负载
（5000 次操作、约 64ms）不足以给出稳定点值，对外只应表述为"亚微秒级"。
历史报告写的"330 / 318 ns/op"精度是虚假的。

---

## 3. Go BadgerDB v4.9.1 对照

**Go 环境：** go1.27.1 linux/amd64 · 同一台机器 · `-cpu=16`（`GOMAXPROCS`=16）
**Go 源码：** `github.com/dgraph-io/badger/v4` tag `v4.9.1`（commit `3290a60`）

### 3.1 纯并发写（唯一语义对齐的一组）

| 实现 | 基准 | 规模 | 中位数 ns/op | 离散度 |
|---|---|---|---|---|
| Go | `BenchmarkWrite` | `-benchtime=5000x`（30 轮） | **149.9** | ±2% ✅ |
| badger-cj | `skiplist_perf` 并发写 | 5000 ops（30 轮） | 387 | ±39.8% ⚠️ |

**比值 ≈ 2.6x**（仓颉更慢）。两侧都已固定 N=5000。

> ⚠️ 这个比值**强依赖**所选的 N —— 见 §3.3。任何跨语言比值都必须同时声明 N。

### 3.2 Go 侧两个 benchmark 的缺陷（已实测确认）

| 基准 | 问题 |
|---|---|
| `BenchmarkReadWrite/frac_10` | **读的是永久空表** —— `NewSkiplist` 在 `b.Run` 闭包内（`skl/skl_test.go:456`），每个 frac 各建新空表；`frac_10` 只 Get 从不 Put |
| `BenchmarkDbGrowth` | 单线程、2000 key/事务、1024B value，与并发事务写无关 |

`frac_10` 实测对照（同一次运行、`-benchtime=5000x`）：

| 子基准 | 数据状态 | ns/op |
|---|---|---|
| `frac_9`（90% 读 + 10% 写） | 有真实数据 | 55.6 |
| `frac_10`（100% 读） | **表为空** | 10.5 – 17.7 |

**因此本报告不引用"Go 100% 读 3.7 ns/op"** —— 那不是读基准。
仓颉的并发读是"预写满 5000 条再读、命中率 100%"，与它**不可比**。

### 3.3 规模敏感性：为什么"1.3x"不成立

Go 的 arena 随 `b.N` **线性增长**（`skl/skl_test.go:511`），而仓颉用**固定** `Arena(32MB)`。
同一份 Go 二进制、同一台机器，仅改变规模：

| Go `BenchmarkWrite` 规模 | ns/op |
|---|---|
| `-benchtime=5000x` | 148 |
| `-benchtime=50000x` | 154 |
| `-benchtime=500000x` | 177 |
| `-benchtime=5000000x` | 227 |
| 默认 `-benchtime=1s`（约 640 万次） | 232 |

历史报告写的 Go 侧 **252.8 ns/op** 对应默认 `-benchtime=1s`（约 640 万次迭代），
而仓颉侧写的是 **330 ns/op**（5000 次操作）。**两者规模差约 1300 倍**，
相除得到的"1.3x"是把两个不同规模的数字放进了同一个比值里，不成立。

**正确表述：** 在 N=5000 的对齐条件下，纯并发写 Go 约 **150 ns/op**、
badger-cj 约 **390 ns/op**（离散度 ±40%），**仓颉版约慢 2.6 倍**。

### 3.4 并发事务写：Go 侧没有可对照的基准

Go v4.9.1 中**不存在**与仓颉 `txn_perf` 语义对齐的基准：

- 根包 22 个 `*_test.go`：零写基准（唯一 `BenchmarkDbGrowth` 是单线程）；
- `badger bank test`：并发事务，但每事务仅 2 个 key，且其**唯一的周期统计输出被注释掉**
  （`badger/cmd/bank.go:427-431`）→ 不产出任何吞吐数字；
- `badger benchmark write`：走 `OpenManaged` 单线程顺序 Set，语义不同。

**故本报告不给出并发事务写的跨语言比值。**

### 3.5 已知不可消除的偏差

| 偏差 | 说明 |
|---|---|
| key 长度 | Go 16B（8B key + 8B 时间戳，`y.KeyWithTs`）vs 仓颉 8B |
| arena 策略 | Go 随 N 缩放 vs 仓颉固定 32MB/256MB |
| 读访问模式 | Go 随机 key vs 仓颉连续切片 |
| jemalloc | 本机未安装，Go 走堆分配（与上游 CI 不同） |

---

## 4. 并发事务写（badger-cj 绝对值）

来源：`badgercj.examples.txn_perf`（50 并发事务，5 轮）

| 规模 | keys/s | ns/op | 离散度 |
|---|---|---|---|
| 50 × 100 | 634,365 | 1,576 | ±13.4% ✅ |
| 50 × 500 | 703,785 | 1,420 | ±10.0% ✅ |
| 50 × 1,000 | **730,396** | **1,369** | ±5.1% ✅ |
| 50 × 2,000 | 691,171 | 1,446 | ±4.6% ✅ |
| 50 × 3,000 | 567,458 | 1,762 | ±2.1% ✅ |

**结论：** 并发事务写在 **57–73 万 keys/s** 区间，事务成功率 100%。
最有代表性的是 1000 key/事务档（离散度最小）：**约 73 万 keys/s、1369 ns/op**。

长事务（500 事务 × 3000 key = 150 万 key）：**382,194 keys/s**（±11.9%，耗时约 3.9s）。

### 相关：单键 vs 批量事务（同一写路径的开关对照）

批量写对每 key 成本的摊薄已实测（见 `docs/progress-tracking.md` 2026-10-02 条）：
同一 40 万 key / 8 线程下，单键事务 **6778–6857 ns/key**，
8 key/事务 **2216–2494 ns/key**（快 2.7–3.1x），64 key/事务 **1715–1969 ns/key**（快 3.5–4.0x）。

---

## 5. flush 落盘影响（同一二进制开关对照）

来源：`badgercj.examples.flush_impact_perf`（小 memtable 1MB、500 轮 × 100 key、数据 48.8MB）

| 写路径 | 写吞吐 (keys/s) | 写耗时 (ms) | close (ms) |
|---|---|---|---|
| io_uring | 97,370 | 513 | 54 |
| sync（降级） | 99,348 | 503 | 50 |
| 离散度 | ±4.8% / ±2.4% ✅ | ±4.9% / ±2.4% ✅ | ±9.3% / ±4.0% ✅ |

**这是同一份二进制、仅切换 `useIoUring` 参数**，因此差异只归因于写路径本身。

**结论：** 两条路径**持平**（sync 甚至略快，但差异在离散度内）。
按 `docs/progress-tracking.md` 的记录，异步 flusher 带来的运行期写吞吐提升
（约 4.6 万 → 9.5 万 keys/s）是 v1.6.17 的改动，**早于 v1.6.21，当前无法重跑旧值对照**；
本表只说明：在 v1.6.21 上，io_uring 与 sync 两条落盘路径的运行期表现相当
（close 均在 **50–54ms** 量级）。

---

## 6. SSTable 批量写：io_uring 明显更慢（同一进程内对照）

来源：`badgercj.examples.sstable_write_perf`（同进程交替跑两侧，取 5 轮最大值）

### 批量写（writeFilesBatch）

| 文件数 | 文件大小 | Sync (ms) | io_uring (ms) | 加速比 |
|---|---|---|---|---|
| 4 | 4 MB | 1 | 6 | **0.16x** ⚠️ |
| 8 | 4 MB | 2 | 11 | **0.18x** ✅ |
| 16 | 4 MB | 5 | 23 | **0.21x** ⚠️ |
| 32 | 4 MB | 9 | 46 | **0.19x** ⚠️ |

### 顺序写（单文件逐个写，baseline）

| 文件数 | 文件大小 | Sync (ms) | io_uring (ms) | 加速比 |
|---|---|---|---|---|
| 4 | 4 MB | 1 | 2 | **0.5x** ✅ |
| 8 | 4 MB | 2 | 5 | **0.4x** ⚠️ |
| 16 | 4 MB | 5 | 9 | **0.55x** ⚠️ |
| 32 | 4 MB | 10 | 17 | **0.58x** ⚠️ |

**结论：** 4MB 小文件的批量写场景下 io_uring **明显慢于** sync write
（批量 **0.16–0.21x**、顺序 **0.4–0.58x**），即慢 2–6 倍。
原因是小文件的提交/完成开销占比过高。
这与 `README.md` 里"io_uring 10-60% 性能提升"的表述**直接矛盾**，该行已修正。

---

## 7. io_uring 的真实边界：不是"总是更慢"

来源：`badgercj.examples.iouring_integration_test` / `iouring_batch_test`（5 轮）

§6 是 4MB 小文件、低并发的场景。换成更大写入量 / 更高并发时，io_uring 会翻盘：

| 场景 | MemTable | 写入量 | Speedup (sync/io_uring) | 方向 |
|---|---|---|---|---|
| 集成 | 2 MB | 100K | **1.6** ⚠️ | io_uring 更快 |
| 集成 | 64 MB | 500K | **1.6** ⚠️ | io_uring 更快 |
| 集成 | 256 MB | 2M | 1.13 ⚠️ | 略快 |
| 集成 | 2 MB | 50K | 0.94 ⚠️ | 持平 |
| 集成 | 1 MB | 50K | 0.71 ⚠️ | io_uring 更慢 |
| 批量 | 1 MB / 16 线程 | 200K | 1.3 ⚠️ | io_uring 略快 |
| 批量 | 1 MB / 8 线程 | 100K | 0.95 ⚠️ | 持平 |
| 批量 | 2 MB / 8 线程 | 100K | 1.19 ⚠️ | io_uring 略快 |

**结论（修正后的完整表述）：** io_uring 的收益**取决于 workload**——

- **小文件、低并发**（4MB SSTable × 4~32 个）：io_uring **慢 2–6 倍**（0.16–0.58x），
  提交/完成开销占主导；
- **大写入量、高并发**（2MB memtable 下 10 万~50 万写、多 imm 表并发 flush）：
  io_uring **可快 1.1–1.6x**。

⚠️ 上表所有 Speedup 的**离散度都在 ±26%~102%**，故只宜作"哪个方向更快"的定性判断，
**不宜引用具体倍数**。

---

## 8. Key 比较：FFI memcmp 实际更慢

来源：`badgercj.examples.key_compare_perf`（100 万次/档，5 轮）

| key 大小 | 逐字节 (ns/op) | FFI memcmp (ns/op) | 倍数 |
|---|---|---|---|
| 16 B | 4 | 72 | **逐字节快 18x** |
| 64 B | 4 | 72 | **逐字节快 18x** |
| 256 B | 4 | 72 | **逐字节快 18x** |
| 1024 B | 4 | 72 | **逐字节快 18x** |

（FFI 侧离散度 ±1.4~2.8% ✅；逐字节侧 3–4 ns/op、离散度 ±25% ⚠️ —— 已接近计时精度。）

**结论：** 仓颉逐字节比较比 FFI `memcmp` **快约 18 倍** ——
FFI 跨语言调用开销（约 70 ns）远大于 `memcmp` 本身节省的 CPU 周期。
这与本报告历史结论一致（历史记为 18–26x）。

> ⚠️ **注意**：本基准测的是"调用开销"，**不能**直接推出"长 key 走 FFI 是负优化"。
> `Node.compareKey` 对 `minLen >= 64` 走 FFI 的分流（`src/skiplist/node.cj`）
> 是否有利，需以跳表端到端延迟为准，本基准不构成证据。

---

## 9. DB 与内存路径微基准

### 9.1 `cjpm bench` 四套件（5 轮中位数）

| 套件 | Case | 中位数 | 离散度 |
|---|---|---|---|
| BufferBench | benchArrayListAddAll | 569.0 us | ±3.7% ✅ |
| BufferBench | benchArrayListAdd | 1,233.0 us | ±9.2% ✅ |
| BufferBench | **benchArrayDirect** | **235.7 us** | ±12.0% ✅ |
| BufferBench | benchByteBufferWrite | 1,227.0 us | ±2.0% ✅ |
| BufferBench | benchByteBufferWriteBytes | 990.0 us | ±3.0% ✅ |
| DBBench | benchDBSet | 15.67 us | ±9.1% ✅ |
| DBBench | benchDBGet | 5.54 us | ⚠️ ±68.5% |
| SkiplistBench | benchPut | 1.044 us | ⚠️ ±45.5% |
| SkiplistBench | benchGet | 1.873 us | ⚠️ ±68.3% |
| TxnBench | benchTxnWrite100 | 508.0 us | ±11.5% ✅ |
| TxnBench | benchTxnWrite500 | 3,022.0 us | ±4.1% ✅ |
| TxnBench | benchTxnWrite1000 | 7,995.0 us | ⚠️ ±15.6% |

**结论：** `Array` 直接索引比 `ArrayList + toArray()` 快 **2.4–5.2x**、
比 `ByteBuffer` 快 **4.2–5.2x**。

> ⚠️ `benchDBGet`（±68%）、`benchPut`（±46%）、`benchGet`（±68%）三项离散度极大，
> **不可引用点值**。历史报告对它们给出的精确数字（如 `benchDBGet 4.834 / 3.447 us`）
> 落在本次实测范围（3.78–7.57 us）之内 —— 说明那不是"版本差异"，而是同一基准的噪声。

### 9.2 端到端小基准

| 基准 | 指标 | 中位数 | 离散度 |
|---|---|---|---|
| `perf`（4000 写 / 4000 读） | DB 写 (ns/op) | 1,431 | ±11.0% ✅ |
| `perf` | DB 读 (ns/op) | 2,681 | ±2.5% ✅ |
| `raw_write_perf`（MemTable 直写 50 万 key） | 写吞吐 (keys/s) | 554,084 | ±4.4% ✅ |

---

## 10. 已废弃的历史数字（不可复现）

以下数字来自"改造前 vs 改造后"对照，而改造早已进入 HEAD，**无法直接重跑旧值**。
按不做跨版本对比的原则，**不应继续对外引用**：

| 历史数字 | 问题 |
|---|---|
| CRC32C 占比 17% → 0.04% | 剖析占比，依赖当时 workload，无独立入口 |
| WAL 性能 +92% | 需旧 `LogEntry::encode` 实现 |
| 写入性能 2–3 倍（移除 updateDiscardStats） | 需带回 `updateDiscardStats` 的构建 |
| 初始化 12% → <1%（AtomicStorage） | 需旧预分配实现 |
| 大事务延迟 100ms → 1ms（Condition） | 需 `Condition` 改造前的构建 |
| close 720ms → 16ms | 指 v1.6.10 之前的集中落盘 |
| **"并发写 330 ns/op = Go 的 1.3x"** | 两侧测量规模差约 1300 倍，比值不成立（§3.3） |
| **"Go 100% 读 3.7 ns/op"** | 该基准读的是空表，不是读基准（§3.2） |
| **版本演进表**（v1.3.1 / v1.6.1+ 各行） | **`v1.3.1` 这个 tag 在仓库中不存在**（最早 tag 是 `v1.2.0`），相关优化提交也早于所有 tag → 对照关系无版本学依据，已删除 |

**替代写法**：去掉数字，用定性描述。例如"把轮询等待改成条件通知后，
大事务等待从轮询周期量级降到即时唤醒"。

---

## 11. 复现方法

```bash
cd ~/Projects/Cangjie/badger-cj
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"

# 全量 5 轮（含环境指纹，数据落在真实盘）
python3 scripts/bench/run-bench.py --runs 5

# 只跑部分项
python3 scripts/bench/run-bench.py --only skiplist,txn,flush_impact
```

产出 `bench-report-<时间戳>.txt`（人读）+ `.json`（机读）。

**测已发布 tag**（保持二进制与发布 revision 一致）：

```bash
git worktree add ../badger-cj-1.6 v1.6.21
cd ../badger-cj-1.6 && cjpm build -j 16
python3 scripts/bench/run-bench.py --repo . --no-build --runs 5
```

### Go 侧对照命令

```bash
cd ~/Projects/Cangjie/.bench-go/badger   # v4.9.1
unset https_proxy http_proxy

# 纯并发写：N 必须与仓颉侧对齐
go test -run='^$' -bench='^BenchmarkWrite$' -benchtime=5000x -count=30 -cpu=16 ./skl

# ⚠️ 不要单独跑 frac_10：它是空表（§3.2），且不加 -benchtime=Nx 会 OOM
```


## 2.0 重测（2026-11-09，阶段 7.3 首轮）

> 方法学同前：真实盘（mount namespace 把 /tmp 重定向到 btrfs 数据目录）、cjHeapSize=12gb、
> **交替 A/B（每轮交换先后）各 9 轮**、报中位数/离散度/配对差/Welch p，禁止引用单轮 best。
> 工具：scripts/bench/ab-compare.py。

### 2.0.0 vs v1.6.23（txn_queue_perf：8 线程 × 5000 事务 × 1 key，WAL mmap）

| 版本 | median ns/txn | 离散度 |
|---|---|---|
| 2.0.0 | **5540** | 11.5% |
| v1.6.23 | 5181 | 6.6% |

配对均值差 +299 ns（Welch p ≈ 7e-4）：**2.0 的写路径比 1.6.23 慢约 6.9%**。

> 这是阶段 7.3 首轮发现的 2.1x 回退修复后的结果。回退根因：分组提交的 WAL 批写第一版用
> ArrayList<Byte> 逐字节追加再 toArray；改为「算总长 → 一块连续内存 → 逐字段 copyTo +
> 增量 CRC → 一次 mmap 写」后收敛到个位数百分比。结论：**2.0 的 mmap/分组提交不是写吞吐
> 优化**，价值在持久性语义（SyncWrites 下每批一次 msync）与内存上界（表/段数据不进 GC 堆）。

### WAL 后端对照（2.0 内部，同一负载）

| WAL 后端 | median ns/txn | 离散度 |
|---|---|---|
| mmap（默认） | **10688** | 166%（受环境干扰，仅作方向性） |
| buffered（mmap:off） | 90619 | 34% |

mmap 后端约 **8.5x** 快于 buffered（buffered 每条日志一次 File.write）。

### 待补

- run-bench.py 全套（skiplist / txn / perf / flush_impact / sstable_write）在 2.0 上的 5 轮复测；
- sst_read_mem_perf 的 mmap:on|off 读延迟对照（1.6.x 已测过零回退，2.0 索引 lazy 化后需复测）。

### 全套复测（2.0.0 / tag v2.0.0 后，2026-11-09，5 轮中位数）

> 原始报告（含环境指纹/波动标注）：docs/bench-2.0-full-report.txt。下面只摘核心项；
> 离散度 > 15% 的项不宜引用点值。

**并发事务写**

| 指标 | 中位数 | 离散度 |
|---|---|---|
| 50x100_ns/op | 1405.00 | 21.6% ⚠️ |
| 50x100_keys/s | 711327.00 | 20.6% ⚠️ |
| 50x100_耗时(ms) | 7.00 | 14.3% |
| 50x500_ns/op | 1398.00 | 5.0% |
| 50x500_keys/s | 714920.00 | 5.1% |
| 50x500_耗时(ms) | 34.00 | 5.9% |
| 50x1000_ns/op | 1268.00 | 6.1% |
| 50x1000_keys/s | 788203.00 | 6.1% |
| 50x1000_耗时(ms) | 63.00 | 6.3% |
| 50x2000_ns/op | 1347.00 | 65.5% ⚠️ |
| 50x2000_keys/s | 741845.00 | 42.1% ⚠️ |
| 50x2000_耗时(ms) | 134.00 | 65.7% ⚠️ |
| 50x3000_ns/op | 1742.00 | 16.0% ⚠️ |
| 50x3000_keys/s | 574021.00 | 15.2% ⚠️ |
| 50x3000_耗时(ms) | 261.00 | 16.1% ⚠️ |

**长事务写**

| 指标 | 中位数 | 离散度 |
|---|---|---|
| 500x3000_keys/s | 336314.00 | 8.6% |
| 500x3000_耗时(ms) | 4460.00 | 8.3% |

**Skiplist 并发**

| 指标 | 中位数 | 离散度 |
|---|---|---|
| 并发写(ns/op) | 382.00 | 35.1% ⚠️ |
| 并发写吞吐(ops/sec) | 2616907.00 | 29.6% ⚠️ |
| 并发读(ns/op) | 330.00 | 30.0% ⚠️ |
| 并发读吞吐(ops/sec) | 3030216.00 | 31.2% ⚠️ |
| 顺序写(ns/op) | 703.00 | 479.7% ⚠️ |
| 顺序写吞吐(ops/sec) | 1421226.00 | 107.4% ⚠️ |
| 顺序读(ns/op) | 1308.00 | 9.9% |
| 顺序读吞吐(ops/sec) | 764107.00 | 10.5% |

**DB 读写**

| 指标 | 中位数 | 离散度 |
|---|---|---|
| DB写(ns/op) | 1248.00 | 21.4% ⚠️ |
| DB读(ns/op) | 2683.00 | 6.4% |

**MemTable 直接写**

| 指标 | 中位数 | 离散度 |
|---|---|---|
| 写吞吐(keys/s) | 502933.00 | 7.0% |

### SSTable 读：mmap vs 整表驻留堆（2.0，A/B 交替 5 轮）

| 数据集 | mmap:on | mmap:off（堆内） | 比值 |
|---|---|---|---|
| 128MB（随机读） | 112.3 µs/Get | 35.5 µs/Get | **mmap 慢 3.2x** |
| 16MB（随机读） | 20.8 µs/Get | 7.6 µs/Get | **mmap 慢 2.7x** |

> 口径变化：v1.6.x 两种模式都是「整表预读进堆」（1.6.x 测得 35.2 vs 35.2 µs，零差异）；
> 2.0 的 mmap 模式按需映射、每块读是 memcpy + 分配，因此比「整表驻留堆」慢。
> 这是**用读延迟换内存上界**的有意取舍（2.0 的目标是表数据不进 GC 堆）：
> 内存模式 128MB 数据需常驻堆（受限堆下即 1.6.x 的 OOM 根因），mmap 模式稳态堆与数据量解耦。
> 每块分配/拷贝带来的开销已登记为 2.1 的 Block Cache / 零拷贝块视图优化项。

### 2.1 Block Cache 效果（sst_read_mem_perf，A/B 交替 5 轮，真实盘）

| 场景（128MB 数据、2 万次随机 Get） | ns/Get | 相对堆内 |
|---|---|---|
| mmap + cache=0（2.0.1 行为） | 113223 | 3.15x |
| mmap + cache=64MB | 36948 | **1.03x** |
| mmap:off（整表驻留堆，参照） | 35911 | 1.00x |

结论：块缓存把 mmap 的随机读延迟从 3.15x 拉回 **1.03x**，命中率收益随数据集/容量变化；
容量为 0（默认）时行为与 2.0.1 完全一致。验收目标「≤ 堆内 1.1x」达成。

### 2.1 L2 流式落盘（flush）写吞吐对照

flush_impact_perf（sync 路径，500 轮 x 100 key x 1KB 约 48.8MB，交替 5 轮、真实盘）：

| 模式 | median keysPerSec | 备注 |
|---|---|---|
| 整表字节（默认） | 80325 | 构建整表后 writeFile |
| 流式落盘（streamingSSTable） | 79095 | 块完成即写文件，构建期不驻留整表 |

差异约 1.5%，在轮间波动范围内 -> 流式落盘在 sync 路径没有可测量的吞吐代价，收益是
flush 峰值内存与表大小解耦（P0-2）。io_uring 分段提交尚未实现：当前流式路径用 File 顺序写，
默认 io_uring 路径仍走旧的整表字节写。

### 低堆 flush 验证（P0-2，2026-11-09）

新增 examples/flush_low_heap（memTableSize=16MB，写约 24MB 触发大表 flush），在 cjHeapSize=64MB 下：

| 模式 | 结果 |
|---|---|
| 整表字节（plain） | OOM（flusher 先报 flush system error，imm 滞留后写路径 OOM） |
| 流式落盘（stream） | OOM（写路径 OutOfMemoryError） |

结论：**64MB 堆配 16MB memTableSize 本身就不成立**——NumMemtables=5 时在途 memtable 的
arena 上限约 5 x 21MB = 105MB，已超堆上限；流式落盘减少的是「单次 flush 的额外整表副本」，
不能抵消 memtable 集合本身的占用。低堆部署的正确姿势是同时调小 memTableSize 与 NumMemtables
（例如 4MB 表 + NumMemtables=2），这块需要后续在 README 给一张对照表；流式落盘的收益
应在「memtable 集合已能放下、flush 峰值内存成为瓶颈」的场景衡量。

### 低堆矩阵（P0-2，cjHeapSize=128MB，写约 24MB 触发大表 flush）

| memTableSize | NumMemtables | 整表字节（plain） | 流式落盘（stream） |
|---|---|---|---|
| 4MB | 2 | **OOM** | **通过（632ms）** |
| 4MB | 5 | OOM | OOM |
| 16MB | 2 | OOM | OOM |
| 16MB | 5 | OOM | OOM |

结论：在「memtable 集合本身放得下」的边界上（4MB 表 + NumMemtables=2），**流式落盘把
原本 OOM 的场景变成可完成**——这正是 P0-2 想要验证的另一个副本收益；但 memtable 集合超限时
（16MB 表，或 NumMemtables=5）流式也救不回来，低堆仍需同时约束这两个参数。

### 2.2 P1-2 / P1-4 效果评估（2026-11-10，2.2.0 之后）

> 目的：P1-2（L2 流式落盘）要决定「默认值是否翻转」；P1-4（arena 调优）设计里写的是
> 「先 profile，有数据再定方案」。本节是这两件事的证据，不是发布记录。

探针与口径：

- `src/examples/mem_profile`（新增）：一次进程做一件事（flush / compact-prepare / compact-run / arena），
  输出 `RESULT` 行含耗时、MB/s、峰值 RSS（`/proc/self/status` 的 `VmHWM`）、arena 已用/分配、单批最大预留。
- `scripts/bench/heap-sweep.py`（新增）：`unshare -rm` 里把 `/tmp` bind 到真实盘，按 `cjHeapSize` 扫描，
  找出**最小可用堆**；失败区分 `oom` / `exit=N` / `timeout`（低堆下写路径可能长时间重试，不当作通过）。
- 吞吐对照用 `scripts/bench/ab-compare.py`（交替 A/B、配对检验）；数据 128MB，mt=16MB，15 轮。
- 机器与 2.0/2.1 各节同机（见 §1 环境指纹）；数据目录 `.bench-data/heap`（btrfs，非 tmpfs）。

#### P1-2-A 低堆边界：同一负载要多少堆才能跑完

负载：1KB 值、每次事务 100 条、共 32MB（flush）/ 67MB 输入（compaction）。失败 = 进程内 OOM 或明确报错。

| 负载 | 整表字节（默认） | 流式落盘 | 峰值 RSS（各自最小通过堆） |
|---|---|---|---|
| flush：mt=16MB、nbMem=2、32MB 数据 | **384MB** 通过（256MB 失败） | **192MB** 通过（128MB 失败） | 381MB → **220MB** |
| flush：mt=4MB、nbMem=2、24MB 数据 | **96MB** 通过（64MB 超时） | **64MB** 通过（48MB OOM） | 128MB → **96MB** |
| compaction：11 张 L0 表、67MB 输入→1 表 | **256MB** 通过（192MB 失败） | **≤32MB 通过** | 415MB → **120MB** |

结论：

- 大表 flush 的最小堆减半（384 → 192MB）；4MB 表这类低堆配置也有 96 → 64MB 的收益。
- **compaction 才是最大受益方**：压缩要建一张新表，整表字节模式把「输出表」整份放在 GC 堆里，
  流式落盘后峰值 RSS 从 415MB 降到 120MB（**3.4×**），最小可用堆从 256MB 降到 32MB 以下。
- 这也解释了旧报告里「16MB 表在 128MB 堆下两种模式都 OOM」：那批测量的瓶颈在**写阶段**
  （memtable 集合 × arena，见 P1-4），不是 flush 那一份副本——两者要分开看。

#### P1-2-B 吞吐：流式有没有代价

128MB 写入（mt=16MB、nbMem=5、1KB 值、每事务 100 条），交替 15 轮，metric = MB/s（写 + flush 全程）：

| 对照 | A 中位数 | B 中位数 | 配对差 | p |
|---|---|---|---|---|
| plain vs stream（io_uring 开） | 120.4 MB/s | **129.2 MB/s** | stream 快 6.8%（SD 13.0） | 0.083 |
| plain vs stream（io_uring 关） | 125.4 MB/s | 126.2 MB/s | 差 0.7%（SD 6.5） | 0.96 |

结论：**没有可测的吞吐代价**，io_uring 路径上方向甚至略快（`TableFileSink` 按块提交、队列深度由
`IoUringFileWriter` 控制，避免整表字节一次性落地）。轮间离散度 16%~72%，所以只能说到这个粒度；
「流式慢」的旧结论（1.5%）也在噪声内。

#### P1-2 建议

把 `Config.StreamingSSTable` **默认改为 true**，依据：

1. 低堆能力实质提升（flush 最小堆减半、compaction 峰值 RSS 降 3.4×）；
2. 吞吐无代价（配对检验 p=0.08 / 0.96）；
3. 2.2.0 已把 io_uring 分段提交与同步回退都接好，默认开不会引入平台依赖（非 Linux 自动回退 `File` 写）。

前置与风险：① 需要在 Windows CI 上跑一轮（流式路径走 File 回退，语义应与整表一致，但尚无实测）；
② 关掉开关必须仍能回到旧路径（现已具备，且这是回滚手段）；③ 建议随 2.3.0 一起发，并在 README 写明
「低堆/大表默认开启」的口径变化。

#### P1-4-A arena 到底占多少：它是 GC 堆内存

`Arena` 的底层是 `Array<Byte>(size, repeat: 0)`——仓颉数组是 GC 托管对象，**arena 计入 `cjHeapSize`**
（这也与低堆实测一致：mt=16MB、nbMem=5 时 5×21MB 的 arena 就吃掉 100MB 以上堆）。

目标容量（与 badger-go 同公式）= `MemTableSize + 15%·MemTableSize + (15%·MemTableSize/96)·106`：

| memTableSize | 目标 arena / 表 | 倍数 | 其中批次预留 |
|---|---|---|---|
| 4MB | 5.52MB | 1.32× | 1.32MB |
| 16MB | 21.05MB | 1.32× | 5.03MB |
| 64MB | 88.29MB | 1.32× | 20.6MB |

稳态利用率（关闭渐进扩容后采样 `MemTableUsedBytes/MemTableArenaBytes`，轮换阈值 = MemTableSize）：

| 值大小 | 采样利用率 | 说明 |
|---|---|---|
| 1KB | 74.3% | 稳态轮换在 MemTableSize，故 ≈ MemTableSize/目标 = 76% |
| 16KB | 76.0% | 同上 |
| 128B | 60.5% | 小值节点开销（106B/条）不进「已用字节」，是口径差异、不是浪费 |

即：**每个 memtable 有约 24% 的 arena 是为「跨阈值那一批」预留的，写满即轮换，那部分平时不用**。
实测单批预留的真实需求（`Stats.MaxBatchBytes`）：

| 负载 | 单批最大预留 |
|---|---|
| 128B 值 × 100 条/事务 | 28KB |
| 1KB 值 × 100 条/事务 | 115KB |
| 1KB 值 × 1000 条/事务 | 1.17MB |
| 16KB 值 × 100 条/事务 | 1.65MB |

对照目标里的预留：4MB 表给 1.32MB（够用）、64MB 表给 20.6MB（是实测最大批的 12 倍以上）。

#### P1-4-B 渐进扩容（P1-6）的冷启动收益

mt=64MB，open 后立刻读 RSS：

| 配置 | open 后 RSS | 首张 memtable arena |
|---|---|---|
| `arenaGrowthStartBytes=256KB`（默认） | **25.2MB** | 256KB |
| `arenaGrowthStartBytes=0`（关闭渐进） | 57.8MB | 86.2MB |

所以 P1-6 在「打开即吃几百 MB」的嵌入式场景确实成立（省 32MB 起步 RSS）。

#### P1-4 建议（不实现，先定优先级）

1. **收紧批次预留**：把预留从 `15%·MemTableSize` 改成 `min(15%·MemTableSize, 2MB)`（节点项按新预留的比例算）。
   收益：64MB 表 arena 88.3→66.4MB（**-21%**）、16MB 表 -12%、4MB 表 -12%；5 张 memtable 时
   64MB 配置的 arena 占用 420→330MB。风险：单批超过预留时会在批中轮换（现有语义已正确，
   16KB×100 用例就超过 4MB 表的预留并正常完成），代价是偶发多一次 rotate。
2. **把预留做成配置**（`Config.MemTableBatchReserveBytes`），默认取上一条公式——给「超大批次」场景留出口。
3. **不做**：把 arena 改成原生内存（FFI `malloc` + 手工生命周期）。收益更大（arena 完全不占 GC 堆），
   但生命周期/越界风险与 `mmapcj` 已铺好的路径不匹配，收益对不上风险，暂不排期。

#### 一句话

- **P1-2：可以翻转默认值**（吞吐无代价、内存收益 2×~3.4×），建议 2.3.0 做，前置是 Windows 旁路验证。
- **P1-4：不需要「调优参数」，需要改那个 15% 预留**——它是 GC 堆里的净浪费，改小省 12%~21%；
  arena 原生化收益更大但属于重构，不在近期。


#### 2.3.0 默认变更复测（2026-11-10）

2.3.0 把两件事从「可选项」变成默认：**流式落盘默认开**、**批次预留封顶 2MB**。复测结论：

**① 流式落盘默认开**：吞吐无代价（见 §2.2 P1-2-B：120.4 vs 129.2 MB/s，p=0.083；io_uring 关时持平），
低堆收益不变（大表 flush 最小堆 384→192MB、compaction 峰值 RSS 415→120MB）。关掉开关仍是回退手段。

**② 批次预留 `min(15%·MT, 2MB)`**：堆边界基本不动（下表为 2.3 复测，与 §2.2 的 2.2 口径相差 ≤1 档），
但**稳态 arena 占用**明显下降。同一二进制只改预留的 A/B（mt=64MB / nb=5 / 写 128MB / 12GB 堆）：

| 预留 | arena/表 | 5 张合计 | 峰值 RSS | flushMs |
|---|---|---|---|---|
| **2.3 默认（封顶 2MB）** | **68.2MB** | **341MB** | **611MB** | 617 |
| 2.2 口径（15% ≈ 9.6MB） | 84.2MB | 421MB | 644MB | 645 |

16MB 表：20.2MB vs 21.05MB（-4%，RSS 差 <1MB）；4MB 表预留仍是 15%，行为不变。

2.3 复测的最小可用堆（与 §2.2 的 2.2 口径对照）：

| memTableSize | numMemtables | 2.3 流式（默认） | 2.3 整表字节 |
|---|---|---|---|
| 4MB | 2 | 64MB | 96MB |
| 16MB | 2 | 192MB | 256MB |
| 64MB | 2 | 768MB | 768MB（2.2 口径 1024MB） |
| 16MB | 5 | 192MB | — |
| 64MB | 5 | 768MB | — |

结论：**预留收紧的收益在稳态占用而不是堆边界**——64MB 表每张少 15.7MB、5 张少 80MB；
堆边界由 GC 余量与建表临时对象决定，预留只是其中一项。这两项收益互补，都随 2.3.0 生效。

