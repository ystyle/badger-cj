# Arena 原生化（memtable 内存移出 GC 堆）子设计

> 状态：**设计稿（未实现）**。父项：docs/plans/2026-11-09-v2.1-plus-design.md 的 P1-4 / §10。
> 目标版本：**2.4**（实现窗口：升级到 cjvs **1.3.0** 之后；1.2.0 上也可做，等 1.3.0 是排期选择）。
> 一句话：把 memtable 的 arena 从 GC 托管数组换成**原生匿名内存**，让 `cjHeapSize` 不再被 memtable 拖住；
> 公开 API、文件格式、并发语义都不变。

## 1. 证据（为什么值得做）

### 1.1 arena 现在是 GC 堆内存，且是堆里最大的单项

`Arena` 的底层是 `Array<Byte>(size, repeat: 0)`（src/arena/arena.cj）。仓颉数组由 GC 托管，
因此 arena **计入 `cjHeapSize`**。2.3 收紧批次预留后的实测：

| memTableSize | 每张 memtable 的 arena | 默认 numMemtables=5 时的在途占用 |
|---|---|---|
| 4MB | 5.52MB | 约 33MB |
| 16MB | 20.2MB | 约 121MB |
| 64MB（库默认） | **68.2MB** | **约 341MB** |

仓颉运行时默认 `cjHeapSize` = 256MB → **默认配置在默认堆下必然 OOM**，这是「调参文档」要教用户算账的根本原因。

### 1.2 生产事故的形态正是「堆没余量」而不是「内存泄漏」

忆时塔 2026-09-15 的生产事故（cangjie-mem `library/570`）：堆上限 256MB、**存活量只有 30~60MB**，
但分配峰值到 217~240MB → `OutOfMemoryError` → 写路径整批 markFailed。同理，低堆实测（benchmark-report §2.2）：

| 配置（1KB 值、每事务 100 条） | 2.3 最小可用堆 |
|---|---|
| 4MB 表 / 2 张在途 | 64MB |
| 16MB 表 / 2 张 | 192MB |
| 64MB 表 / 2 张 | **768MB** |

把 arena 移出 GC 堆，等于把这 341MB（默认配置）从「堆上限」里整块摘掉——**这是唯一能根治该结构的改动**，
收紧预留（2.3 已做，-19%）只是缓解。

### 1.3 为什么不用「文件 mmap」也不用 source-set

- **文件 mmap 不适合 arena**：arena 是可变 bump 分配器（32 位 offset + 连续可写），文件映射要付出
  预分配/删除文件、脏页回写、Windows 先 close 再 unlink 等代价（2.0 设计 §3.2 已定为非目标）。
  真正对应的是**原生匿名内存**（`malloc` / `mmap(MAP_ANONYMOUS)`），不占堆、无文件生命周期。
- **source-set / features 不能用**：该特性是 cjpm experimental，消费者必须同样开 `[profile] experimental = true`，
  否则连库都编不过——mmap-cj 实测后回退（`fcb774e` → `698e673`，v1.1.0 起单 src + `@When`）。
- **平台差异用 `@When[os == ...]` 处理**（内置条件、消费方无感）；**用户是否启用用运行时 `Config`**
  （自定义 cfg 有三条硬约束：未定义即编译错误、库定义后消费方无法覆盖、只能全局一份值）。

## 2. 目标与非目标

### 2.1 目标

1. arena 内存**不占 GC 堆**（`cjHeapSize` 与 memtable 解耦）；
2. 默认配置（64MB × 5 张）不再需要 341MB 堆余量；
3. 公开 API / 文件格式 / 并发语义 / 现有配置项语义**一律不变**；
4. 保留 GC 后端作为**回滚与对照**（一个 `Config` 字段切换）；
5. 越界从「静默破坏」变成「可诊断」：保留显式边界检查 + 测试期 canary。

### 2.2 非目标

- 不做文件 mmap arena；不做 source-set/features 变体；
- 不改跳表结构、不改 `MemTable` 的对外语义（offset 仍是 `UInt32`）；
- 不在本阶段动 `AtomicStorage`（节点索引，见 §8 阶段 B）；
- 不追求「零拷贝」或大页优化（§8 阶段 C）。

## 3. 方案

### 3.1 Arena 后端抽象

```cangjie
// src/arena/arena.cj
protected interface ArenaBackend {
    func base(): CPointer<UInt8>       // 起始地址（原生后端）；GC 后端用 Array 切片
    func capacity(): Int64
    func close(): Unit                 // 幂等
}
```

实现两个后端：

| 后端 | 存储 | 何时用 |
|---|---|---|
| `GcArenaBackend` | 现状 `Array<Byte>` | 默认（2.4.0），回滚与 A/B 对照 |
| `NativeArenaBackend` | FFI `malloc` 得到的 `CPointer<UInt8>` + `free` | `Config.ArenaBackend = Native` |

`Arena` 的对外接口（`allocate/putBytes/getBytes/putNode/usedSize/size`）**完全不变**，
skiplist 与 memtable 一行不用改。

### 3.2 为什么先 `malloc` 而不是 `mmap(MAP_ANONYMOUS)`

- `malloc` 对 ≥128KB 的请求在 glibc 上走 `mmap` 后端，本身就是匿名映射，
  且三平台（Linux/macOS/Windows CRT）统一，**不需要平台分支**；
- `mmap(MAP_ANONYMOUS)` 的额外好处是可以用 `madvise(MADV_FREE/DONTNEED)` 提前归还页、
  以及更容易做 guard page（恰好是测试需要的）→ 列为**阶段 C 的可选优化/测试手段**，不是首版必需；
- 若将来要 huge page / guard page，再在 `@When[os != "Windows"]` 下加 `mmap` 后端，Windows 用 `VirtualAlloc`。

### 3.3 生命周期

- 分配：`MemTable` 构造时按目标容量（arena_sizing.cj 的公式）分配；渐进扩容沿用现有逻辑（每张表各自分配）；
- 释放：挂到 `MemTable.decrRef()` —— 与「删 WAL」同一处（表不可变、写满即轮换，内部不需要回收）；
- 关库：`Badger.close()` 的兜底 flush 之后走同一路径；
- **失败即抛**：`malloc` 返回 null → 抛 `BadgerException.outOfMemory`（信息含请求字节数），
  比 GC 的 `OutOfMemoryError` 更早、更可诊断；调用方（`rotateAndEnqueueLocked` 的阶段 1）本来就是「可抛且零状态变更」。

### 3.4 对齐与边界

- `malloc` 返回的地址至少 16B 对齐（glibc/CRT 保证），满足 arena 的 8B 节点对齐要求；
  构造时断言 `Int64(base) % 8 == 0`（测试期），不满足直接失败（不静默降级）；
- **保留 `allocate` 的显式溢出检查**（现状已有：超过容量抛异常）——原生内存越界是 UB，
  这个检查是唯一防线，不许在优化里去掉；
- 测试期 canary：`@When[test]` 下 `malloc(size + 16)`，尾部 8B 写哨兵，
  `close()` 时校验 → 捕获「差一点越界」的写入；生产构建不含该分支（零成本）。

### 3.5 配置与统计

```cangjie
public enum ArenaBackendKind { Gc | Native }   // 注意：枚举不能 == 比较，用 match 分发

Config(
    arenaBackend!: ArenaBackendKind = ArenaBackendKind.Gc,   // 2.4.0 默认 Gc，翻默认见 §4
)
```

`Stats` 补两个字段：

| 字段 | 含义 |
|---|---|
| `ArenaBackend` | 当前后端（诊断：线上确认跑的是哪条路径） |
| `ArenaNativeBytes` | 原生 arena 当前占用（GC 后端时为 0）；配合 RSS 判断真实占用 |

## 4. 默认值策略（不激进翻转）

沿用 2.3 的「先给开关、跑下游、再翻默认」节奏：

| 版本 | 默认后端 | 理由 |
|---|---|---|
| 2.4.0 | `Gc` | 新路径先 opt-in；下游与应用各跑一轮，收集低堆/RSS/吞吐 |
| 2.5.0 | `Native`（拟） | 满足 §6 验收 + 三平台 CI 连续绿 + 至少一个生产实例跑通后 |

翻默认的**判据**（写死，避免拍脑袋）：

1. §6 的 5 项验收全部达标；
2. 三平台 CI（Linux required，Windows/macOS 观察）连续 3 次绿；
3. 至少一个真实应用（忆时塔或 cjreg）用 `Native` 跑满一轮回归 + 一次重启恢复；
4. 回滚开关可用且被验证过（关闭后行为与 2.3 逐字节等价）。

## 5. 代码改动清单

| 文件 | 改动 |
|---|---|
| `src/arena/arena.cj` | 抽 back end；`Arena` 对外签名不变；`close()` 幂等；测试期 canary |
| `src/arena/arena_native.cj`（新） | `NativeArenaBackend`：FFI `malloc/free` + 对齐断言 |
| `src/db/config.cj` | `ArenaBackendKind` + `arenaBackend` 字段/命名参数 |
| `src/db/memtable.cj` | 构造传后端；`decrRef()` 释放 arena；容量查询不变 |
| `src/db/badger.cj` | 透传配置；`getStats()` 补字段；轮换/扩容逻辑不变 |
| `src/db/stats.cj` | `ArenaBackend` / `ArenaNativeBytes` |
| `src/arena/arena_native_test.cj`（新） | 分配/读写/对齐/容量溢出/canary/释放计数 |
| `src/db/arena_backend_test.cj`（新） | 两种后端语义等价：写读回、重开、批量跨轮换、压缩后读 |

## 6. 测试与验收（数字必须可复核）

| # | 项 | 现状（2.3，Gc） | 目标（Native） | 怎么测 |
|---|---|---|---|---|
| 1 | 64MB 表 / 2 张最小可用堆 | 768MB | **≤256MB** | `heap-sweep.py --bisect` |
| 2 | 16MB 表 / 5 张最小可用堆 | 192MB | **≤128MB** | 同上 |
| 3 | 默认配置（64MB×5）稳态 arena 堆占用 | 341MB | **0**（`ArenaNativeBytes` ≈ 341MB，RSS 不变） | `mem_profile` + `Stats` |
| 4 | 写吞吐（128MB、1KB 值、A/B 交替 15 轮） | 基线 | **≥ -3%** | `ab-compare.py` |
| 5 | memtable get/iterate（内存态微基准） | 基线 | **≤ +5%** | `cqpm bench` / memtable 微基准 |
| 6 | 正确性 | — | 全量用例 + 三平台 CI 绿；新增越界/分配失败/泄漏用例 | `cjpm test` |

> 说明：目标 1/2 的余量来自「arena 移出堆」——64MB 表 2 张 = 136MB 从堆里消失，
> 但最小可用堆还受建表临时对象与 GC 余量支配，所以目标定 256MB 而不是「减 136」。

## 7. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| 越界写 | 进程崩溃/静默破坏（GC 数组会抛异常，原生指针不会） | 保留 `allocate` 显式检查；`@When[test]` canary；阶段 C 可选 guard page |
| 内存泄漏 | RSS 单调增长 | 释放挂 `MemTable.decrRef`（已有路径）；用例断言「分配次数 == 释放次数」；长稳压测看 RSS 曲线 |
| FFI 平台差异 | 编译/运行期失败 | 只用 C 标准 `malloc/free`（三平台一致）；对齐断言 fail-fast |
| 分配失败 | 写入失败 | `malloc` 为 null 即抛明确异常，走现有「轮换可抛、零状态变更」路径 |
| 与 `AtomicStorage` 混用 | 只移一半，收益打折 | 本阶段只动 arena；`AtomicStorage` 单列阶段 B（它涉及并发原子语义，风险更高） |
| 渐进扩容/预留公式交互 | 行为变化 | 公式（arena_sizing.cj）只管「要多少字节」，与后端无关；用例覆盖 `arenaGrowthStartBytes` / `MemTableBatchReserveBytes` 组合 |
| 回滚不干净 | 出问题无法退回 | 两条后端并存到 2.5 之后；翻默认前验证「关闭后行为与 2.3 等价」 |

## 8. 分期

| 阶段 | 内容 | 门槛 |
|---|---|---|
| **A（2.4.0）** | arena 原生后端 + `Config.ArenaBackend`（默认 Gc）+ 用例 + §6 全部验收 | 本文 §6 达标 |
| B（2.4.x/2.5） | `AtomicStorage`（节点索引）原生化：需要原生内存上的原子操作 → 先评估 FFI 原子/无锁方案，风险更高，单独立项 | A 稳定运行一个周期 |
| C（可选） | `mmap(MAP_ANONYMOUS)` 后端 + `madvise` 归还页 / guard page / huge page | B 完成或明确不做 |

## 9. 待定问题

1. **默认翻 Native 的版本**：按 §4 判据走，暂定 2.5.0；若下游/应用一轮就全绿可提前。
2. **是否引入 `madvise` 提前归还**：arena 写满即轮换、整块释放，收益主要在「渐进扩容早期的小表」；先用数据说话。
3. **`AtomicStorage` 是否同批**：建议分开（它承载并发元数据，原生化需要原子原语，风险与本阶段不同量级）。
4. **大页**：64MB arena 用 2MB 页可减少 TLB miss，属调优项，不与正确性改造混做。

## 10. 触发条件

- **排期**：升级到 cjvs **1.3.0** 后开工（用户决策，2026-11-10）；
- 开工前先核对 1.3.0 的 FFI / `std.posix` 是否有破坏性变化（若 `LibC.malloc` 路径变动，先修 FFI 声明）；
- 你在 1.3.0 线提交的 cjpm **source-set 补丁**与本设计**无依赖**：它只影响「整套变体」类需求，
  本设计用的是「平台差异 `@When` + 用户选择 `Config`」；补丁若合入，仅作为将来的可选路径记录在此。
