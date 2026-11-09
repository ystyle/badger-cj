# 基准测试方法学

> 本文说明 **badger-cj 的性能数字是怎么测出来的**，以及为什么必须这么测。
> 可执行入口：[`scripts/bench/run-bench.py`](../scripts/bench/run-bench.py)；
> 结论数据见 [`benchmark-report.md`](benchmark-report.md)。

## 一、为什么要有这套流程

历史基准数据存在四个已实测确认的方法学缺陷。它们不是"精度不够"，而是会**给出错误结论**。

### 缺陷 1：数据目录落在 tmpfs 上，I/O 成绩虚高一个数量级

所有 `src/examples/*` 基准都把数据目录硬编码为 `/tmp/...`：

```bash
$ grep -rn '"/tmp' src/examples/
src/examples/flush_impact_perf/main.cj:20:    let dir = "/tmp/badger_flush_impact"
src/examples/txn_perf/main.cj:26:    let dir = "/tmp/badger_txn_perf_${numTxns}_${keysPerTxn}"
src/examples/sstable_write_perf/main.cj:12:    let testDir = "/tmp/sstable_batch_write_${...}"
...  # 共 9 处
```

而 `/tmp` 通常是 tmpfs —— **读写全在内存里，没有磁盘语义**：

```bash
$ findmnt -no FSTYPE /tmp
tmpfs
```

实测后果：`sstable_write_perf` 在 tmpfs 上算出 `sync` 吞吐 **4021 MB/s**，这是内存速度，
不是磁盘速度。报告里那些毫秒级的 SSTable 写入数字，**在 tmpfs 上没有意义**。

**本流程的做法**：把数据目录显式指定到真实盘，并把文件系统类型记进报告头。
为不改动被测源码（保持二进制与发布 revision 一致），用私有 mount namespace 重定向：

```bash
unshare -rm bash -c "mount --bind <真实盘目录> /tmp && exec <基准命令>"
```

> ⚠️ **一个连带坑**：`cjvs env` 给出的 `CANGJIE_HOME` 位于 `/tmp/cjvs_multishells/<n>_<ts>`
> （那只是个指向 `~/.config/cjvs/store/<ver>` 的软链）。一旦把 `/tmp` bind 掉，这个软链
> 就被遮住 → 进程报
> `error while loading shared libraries: libcangjie-runtime.so`（exit 127）。
> 所以 bind 场景下必须同时把 `LD_LIBRARY_PATH` 指到 store 的真实路径。
> `run-bench.py` 的 `resolve_runtime_libs()` 已处理这一点。

### 缺陷 2：负载太小，单次测量没有统计意义

`skiplist_perf` 全部 4 项总耗时仅约 **64ms**（5000 ops / 16 线程）。单次运行的数字
在 15 轮复测里实测波动幅度：

| 指标 | 15 轮实测范围 | 相对离散度 |
|---|---|---|
| 并发写 | 341 – 468 ns/op | **±32%** |
| 并发读 | 288 – 380 ns/op | ±24% |

也就是说，**单跑一次得到的"330 ns/op"和"380 ns/op"没有区别**，都是噪声。
历史报告里那些精确到个位数的 ns/op，精度是虚假的。

**本流程的做法**：每项连跑 N 轮（默认 5），报**中位数 + 离散度**；
离散度 > 15% 的项自动标 `⚠️波动大` —— 这类项**不足以支撑结论，只宜作定性描述**。

### 缺陷 3：环境指纹缺失

没有 CPU、内核、编译器版本、commit 的记录，数字既不能复核也不能横向比较。

**本流程的做法**：指纹与结果写进同一份报告（`benchmark-report-*.txt` + `.json`）。

### 缺陷 4：跨语言对照的规模不对齐

Go 版 `skl` 基准的 arena 随 `b.N` **线性增长**（`skl/skl_test.go:456`、`:511`），
而仓颉 `skiplist_perf` 用**固定** `Arena(32MB/256MB)`。于是同一份 Go 二进制、
同一台机器，仅改变测量规模就会得到完全不同的 ns/op：

| Go `BenchmarkWrite` 规模 | ns/op（16 线程中位数） |
|---|---|
| `-benchtime=5000x` | **148** |
| `-benchtime=50000x` | 154 |
| `-benchtime=500000x` | 177 |
| `-benchtime=5000000x` | **227** |

规模差 1000 倍，读数差 **53%**。所以"比 Go 慢 1.3 倍"这类比值，
**必须先声明两侧的 N 是多少**；不声明 N 的跨语言比值没有意义。

**本流程的做法**：跨语言对照固定 `-benchtime=<N>x`，与仓颉侧的 `n` 严格对齐。

---

## 二、一套可核验的对照长什么样

### 2.1 只做"当前 HEAD 绝对值"与"同一二进制内开关对照"

跨版本对比（v1.3.1 → v1.6.12 那种）要求 checkout 旧提交、在同一台机器同一次会话内
交替跑完，环境噪声极难控制，而且历史版本演进表**必须能与 git tag 一一对应**才可信
（详见下文 §四）。本流程**不做跨版本对比**，只做两类：

1. **当前 revision 的绝对值**：多轮中位数 + 离散度；
2. **同一二进制内的开关对照**：切换配置参数（如 `useIoUring`），两侧代码完全相同。

### 2.2 开关对照的正确姿势

不要拿"改前构建"和"改后构建"比 —— 那是跨版本。要做的是**同一份二进制、只切开关**：

```bash
# flush_impact_perf 支持 sync 参数切换写路径（io_uring vs 同步降级）
./target/release/bin/badgercj.examples.flush_impact_perf          # io_uring
./target/release/bin/badgercj.examples.flush_impact_perf sync     # sync
```

这样得到的差异**只归因于那个开关**，不掺杂编译器/代码变更。

### 2.3 对照必须看分布，不能只看最佳值

同一实验在 10 轮里，A 方案 9 轮胜出 vs 5 轮胜出，是完全不同的结论。
只看"最佳轮"会把 8% 的真实提升和 0% 的无差异都测成"差不多"
（这一教训已记录在 `docs/progress-tracking.md` 的 `feat/reusable-latch` 条目里）。

---

## 三、运行方式

```bash
cd ~/Projects/Cangjie/badger-cj
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"

# 全量（默认 5 轮）
python3 scripts/bench/run-bench.py

# 更多轮次（中位数更稳）
python3 scripts/bench/run-bench.py --runs 15

# 只跑部分项
python3 scripts/bench/run-bench.py --only skiplist,txn,flush_impact

# 列出所有基准
python3 scripts/bench/run-bench.py --list

# 测某个已发布 tag（先检出到独立 worktree，再指过去）
git worktree add ../badger-cj-1.6 v1.6.21
cd ../badger-cj-1.6 && cjpm build -j 16
python3 scripts/bench/run-bench.py --repo . --no-build
```

### 机器必须空载

基准对 CPU 争用极敏感。运行前确认 `uptime` 的 1 分钟负载接近 0；
脚本在负载 > 2.0 时会打印警告。**不要**在跑构建、跑测试、开浏览器视频的同时测基准。

### 输出

报告落在 `<repo>/.bench-data/bench-report-<时间戳>.{txt,json}`：

- `.txt` —— 人读：环境指纹 + 每项的中位数/离散度/各轮原始值；
- `.json` —— 机读：便于再次加工或做长期趋势。

---

## 四、哪些历史数字不能引用

以下数字来自"改造前 vs 改造后"的对照，而**改造早已进入 HEAD，无法直接重跑旧值**。
按 §2.1 的原则（不做跨版本对比），这些数字**不应继续对外引用**，
除非真的 checkout 旧提交在同一会话内交替测完：

| 数字 | 问题 |
|---|---|
| CRC32C 占比 17% → 0.04% | **剖析占比**，依赖当时 workload；现无独立入口 |
| WAL 性能 +92% | 需旧 `LogEntry::encode` 实现 |
| 写入 2–3 倍（移除 updateDiscardStats） | 需带回 `updateDiscardStats` 的构建 |
| 初始化 12% → <1%（AtomicStorage） | 需旧预分配实现 |
| 大事务延迟 100ms → 1ms（Condition） | 需 `Condition` 改造前的构建 |
| close 720ms → 16ms | 指 v1.6.10 之前的集中落盘 |

**替代写法**：去掉数字，用定性描述。例如
"把轮询等待改成条件通知后，大事务等待从轮询周期量级降到即时唤醒"。

### 版本演进表的额外要求

若要保留任何"vX.Y.Z 基线 / 优化后"的对照，**表里的版本号必须真能在仓库里找到**。
历史 `benchmark-report.md` 的演进表引用了 `v1.3.1`，而该 tag 在仓库中并不存在
（最早的 tag 是 `v1.2.0`），相关优化提交也早于所有 tag —— 这样的表对外会被质疑。
核对方法：

```bash
git tag | sort -V            # 有哪些 tag
git log --oneline -S "<符号>" -- <路径>   # 某改动最早出现在哪个提交
git describe --contains <commit>          # 该提交进了哪个 tag
```

---

## 五、Go 原版对照：三个已确认的陷阱

### 陷阱 1：`frac_10` 读的是永久空表

`skl/skl_test.go` 的 `BenchmarkReadWrite` 里，`l := NewSkiplist(...)` 位于
**`b.Run` 闭包内部**（`:456`）—— 每个 `frac_*` 子基准各建一张**新空表**。

`frac_10` 的 `readFrac = 1.0`，于是**只 Get、从不 Put** → 表永远为空 → 命中率 0。
实测对比（同一次运行、`-benchtime=5000x`）：

| 子基准 | 数据状态 | ns/op |
|---|---|---|
| `frac_9`（90% 读 + 10% 写） | 有真实数据 | **55.6** |
| `frac_10`（100% 读） | **表为空** | **10.5 – 17.7** |

所以报告里"Go 100% 读 3.7 ns/op"**不是一个读基准**，而是"在空表上走一趟 head 比较"。
它**不能**与仓颉"预写满 5000 条后再并发读（命中率 100%）"对照。

> 附带：单独跑 `frac_10` 且不加 `-benchtime=<N>x` 会 **OOM 崩溃** ——
> arena 按 `(b.N+1) * MaxNodeSize` 分配，纯读时 `b.N` 被外推到约 13.5 亿 → 约 130GB arena。

### 陷阱 2：key 长度不等价

Go 的 `randomKey`（`skl/skl_test.go:440`）先造 8 字节，再由 `y.KeyWithTs`（`y/y.go:113`）
**追加 8 字节时间戳** → 实际参与比较的是 **16 字节**。
仓颉 `skiplist_perf` 的 `randomKey` 是**纯 8 字节**。key 长度翻倍会影响比较分支数
与 cache 占用，这个偏差**无法消除**，只能显式记录。

### 陷阱 3：Go 侧语义对齐的基准并不存在

- **纯并发写**：`BenchmarkWrite`（`skl/skl_test.go:509`）—— 可用，语义对齐。
- **并发读**：只有 `frac_10` 那一个子基准，且如上所述是空表；
  **没有**"预写满再读"的基准，严格对照需新增。
- **并发事务写**（对齐仓颉 `txn_perf`）：Go v4.9.1 **完全没有**。
  根包 22 个 `*_test.go` 里只有 `BenchmarkDbGrowth`（单线程、1024B value）；
  `badger bank test` 是正确性不变式测试，其**唯一的统计输出被注释掉**
  （`badger/cmd/bank.go:427-431`），不产出任何吞吐数字；
  `badger benchmark write` 走 `OpenManaged` 单线程顺序 Set，语义不同。

**结论**：跨语言对照只在"纯并发写"这一项上是干净的；其余项目应当
**要么明确标注不可比，要么不给数字**。

---

## 六、已知的、无法消除的偏差

诚实记录比假装精确更有价值：

| 偏差 | 说明 |
|---|---|
| Go key 16B vs 仓颉 8B | 见 §五 陷阱 2 |
| Go arena 随 N 缩放 vs 仓颉固定 | 见 §一 缺陷 4 |
| Go 读基准为随机 key vs 仓颉为连续切片 | 访问模式不同 |
| Go 无 jemalloc | 本机 `HAS_JEMALLOC` 为空，走 Go 堆分配，与上游 CI 不同 |
| 波动项 | 离散度 > 15% 的项已标注，其点值不可引用 |
