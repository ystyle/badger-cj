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
