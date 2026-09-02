# 修复报告: 运行期 memtable flush 不落盘 → OOM/MCP 挂起（及复现中新发现的重启丢读）

- **报告日期**: 2026-09-02
- **关联 Issue**: `docs/issue/2026-09-02-flush-no-persist-oom-mcp-hang.md`（严重性：高）
- **范围**: badger-cj（write/flush/read 路径）；下游 jsonrpc/mcp-cj 联动建议见 §5.5（独立工单，不属本提交）
- **状态**: 已复现（本报告）；修复待实施

---

## 1. 复现结论摘要

在 `badger-cj` 内用自造数据（`/tmp` 临时目录，未触碰生产数据）完成复现，除 issue 主诉外还**新发现两个独立数据正确性缺陷**：

| 编号 | 缺陷 | 复现证据 | 严重性 |
|---|---|---|---|
| **R1**（issue 主诉） | 运行期 memtable flush 只建内存 L0 表：**不写盘、不更新 MANIFEST**；imm/L0 内存表只增不减 → 崩溃丢已 flush 数据 + 长期运行内存无限增长 → OOM | 写入 8 轮触发 **11 次 flush**：L0 内存表 1→11 单调增长，磁盘 `.sst`=0、MANIFEST=0 字节 | 高 |
| **R2**（新发现） | reopen 时 SSTable **被加载两次**（LevelsController 构造与 Badger.open 各调一次 loadTables）→ 每张表双份驻留内存 | reopen 后 `db.tables()` 输出 12 张表 = 6 个文件 id × 2 | 中（内存翻倍，读取正确性不受影响） |
| **R3**（新发现，最严重） | close 落盘**完整**后重启，磁盘表 key **大部分读不出**（45/160，旧轮全 miss、最新轮 40/40）→ 用户视角"重启丢数据" | 同步写/io_uring 双配置一致复现；6 个 `.sst` 文件完整（各 ~1MB） | 高 |

> ⚠️ **R3 是 R1 修复的必要配套**：R1 修复让运行期 flush 正常落盘后，重启读多张 L0 表是常态，R3 会立即发作。两者必须同批修复、同批回归。

复现用例（TDD 形式，修复后应通过，已留作回归测试）：
`badger-cj/src/db/flush_persist_regression_test.cj`

```shell
cd badger-cj && eval "$(cjvs env bash)"
cjpm test --show-all-output --filter 'FlushPersistRegressionTest.*'
# 当前结果：2 个用例 FAILED（= 复现成功），详见 §2
```

## 2. 复现方法与实测数据

环境：宿主直跑（io_uring 可用）+ `useIoUring: false` 对照（等效容器降级同步写），结果一致。

方法：`Config(dir: /tmp/badger_flush_repro_*, memTableSize: 1MB, numLevelZeroTables: 1000)`（放大 L0 阈值以**隔离 flush 落盘与 compaction 落盘**两条路径）；每轮 `batchSet` 40×40KB ≈ 1.6MB，多轮触发多次 flush。

### 2.1 R1 实测（运行期 flush 零落盘）

```
[repro] round 0: L0 tables=1 sstOnDisk=0 memFiles=0
[repro] round 1: L0 tables=2 sstOnDisk=0 memFiles=1
...
[repro] round 7: L0 tables=11 sstOnDisk=0 memFiles=1
[repro] FINAL L0 in-memory tables=11 sstOnDisk=0 MANIFEST bytes=0
```

- 11 次 flush 全部只进内存；`.sst`=0、MANIFEST=0 字节
- `memFiles=1`：已 flush 表的 WAL 已被 `decrRef` 删除（唯一持久副本消失），只剩当前 mt 的 WAL
- **内存证据**：L0 内存表（≈每次 flush 一份 SSTable data）随 flush 单调增长且无 compaction 时**永不释放**；同时每张表仍留在 imm（`getMemTables` 语义），数据双份驻留 → 无限增长 → OOM 必然（issue 生产已观察到 `OutOfMemoryError`）

### 2.2 R3 实测（close 落盘完整但重启丢读）

```
useIoUring=false after close: sstOnDisk=6 MANIFEST bytes=72
  sizes=[000015.sst=1081897 ... 000010.sst=1001782]   # 6 个文件全部完整 ~1MB
useIoUring=false reopened tables: [id=10 keys=25] [id=11 keys=27] ... (6 个 id 各 ×2 = 12 张)
useIoUring=false after reopen: keys=45/160 rounds: r0=2/40 r1=1/40 r2=2/40 r3=40/40
```

- 数据**全部落盘且加载**（表 keyCount 25~27 × 6 ≈ 160），但重启后只有最新一轮（r3，其存储 ts == 恢复后 readTs）可读，旧轮几乎全 miss
- `useIoUring: true`（默认）结果一致 → **与 io_uring/降级路径无关**，是读路径缺陷

## 3. 根因链（代码级）

### 3.0 来源考古（R1 是移植历史遗留，不是性能优化回归）

`flushToLevel` 自诞生起就无写盘代码，后续也没有提交删除过写盘（git 历史无删行痕迹）：

| 提交 | 日期 | 对 flush 路径的动作 |
|---|---|---|
| `c172502` Task 4 DB API | 03-08 | **首次实现** `flushMemTableInternal`/`flushToLevel`：`imm.add` → 建表 `addTable(0)` → `decrRef`。当时 L0 还是 MockTable（全内存阶段），无落盘属阶段性半成品 |
| `24309e8` close() flush and persistence | 03-10 | 持久化落地：新增 `flushMemTableToDisk`（写 SSTable+MANIFEST），**只挂 close()** 遍历 mt+imm 落盘；运行期 flush 保持内存表，**未接入落盘** ← 架构定型点 |
| `e03e37a` | 03-14 | flushToLevel 内 MockTable → 真 `Table`（内存表示），仍不写盘 |
| `5b61b7b`/`689a1c4`/`c1031ce` | 03-13/03-21 | compaction 落盘与 close 批量 io_uring 写是**新增落盘点**，flushToLevel 依旧无写盘 |
| `806eb03` | 08-31 | 只加注释：评审把「异步化 vs 同步构建」闭环为"不做异步化"，注释措辞假设 flush 会"写盘+从 imm 移除"，但**"运行期从不落盘"从未被显式决策或质疑**——盲区 |

即：R1 = 移植时（Task4 骨架 + 03-10 持久化实现）把 badger-go 的「flush 必写 L0 SSTable」语义改成了「运行期 flush 只建内存表、落盘由 close/compaction 兜底」，低频写入下兜底永不触发 → OOM/崩溃丢数据。**非性能优化删功能**；性能类提交（WAL 缓冲、队列、编码等）从未触碰 flushToLevel。

R3 同理是遗留：`findBlock` 当前形态定稿于 `24309e8`（该提交曾修 BlockIterator.seek/findBlock 的初版块定位错误），但未覆盖「seek 版本 ≥ 组内最大存储版本」场景；此后未再改动。未被发现的原因：既有持久化测试都是 close→reopen 全读，close 把所有 key 落同批表且表内 ts 覆盖至 readTs（seek 精确命中），而「多次运行期 flush + 每表不含最新 ts」的多表场景从未被测试覆盖。

### 3.1 R1：运行期 flush 无落盘 + imm/L0 内存表只增不减

写路径：`putPrepared`（badger.cj:680-692）条目级检查 `mt.shouldFlush()` → `flushMemTableInternal`（badger.cj:584-596）：

```
imm.add(mt); mt = MemTable(...)            // 旧表进 imm（运行期从不移除，仅 close 时 clear）
flushToLevel(imm[last])                    // badger.cj:598-617
```

`flushToLevel`：构建 SSTable → `Table(tableID, data)` → `lc.addTable(0, TableAdapter(table))`。**无写盘调用、无 MANIFEST 记录**（对比 `flushMemTableToDisk`/`flushMemTablesBatch`——只在 close 时才执行，badger.cj:213-241）。随后 `mt.decrRef()`（memtable.cj:151-156）把该表 WAL 删掉 → 已 flush 数据在磁盘上**无任何副本**（WAL 已删、SSTable 未写），进程崩溃即永久丢失；不崩溃则数据双份驻留内存（imm + L0 内存表），无 compaction（L0 表数 ≤ `NumLevelZeroTables`=4，低频写入场景）时永不释放 → 无限增长 → GC 堆 OOM。

设计注记：`flushMemTableInternal` 注释（badger.cj:588-594）记录的评审决策仅涉及"是否把 flush 移出写锁/异步化"，**从未论证"flush 不落盘"**——不落盘是移植缺口（badger-go 的 flush 必写 L0 SSTable + manifest change）。

### 3.2 R3：磁盘表读路径 seek 定位错误 → 稳定 miss

key 编码（helpers.cj:23-41）：`keyWithTs` 对 ts **按位取反** → 同 user key 多版本按 **ts 降序**排列（最新版本是"组首"）。

- memtable 读（memtable.cj:106-125）：`findGe(seekKey)` 是"后继"语义 → 用 `keyWithTs(key, readTs)` 定位总能落到组内正确位置（组内第一个 ≤ readTs 的版本）✓
- 磁盘表读（table_adapter.cj:25-52）：`findBlock(keyWithTs(key, readTs))` 块级二分（table.cj:117-142）要求**块首 ≤ key**；当 `readTs ≥ 该 user key 在本表的存储最大 ts` 时（重启后 readTs = 库级最新版本，旧表里几乎每个 key 都如此），seekKey `(k, readTs)` 反序编码后**小于含 k 的块首**（块首即该 user key 组首 = 组内最大版本）→ 二分回退到**前一块** → 块内 seek 到块尾无同 key → **miss**

实测分布完美吻合：r3（ts == readTs，精确命中块首）40/40；r0~r2（readTs > 组最大 ts）几乎全 miss。运行期不暴露是因为 imm/mt 先命中；**R1 修复（imm 落盘即清）后该缺陷成为重启读的必现路径**。

### 3.3 R2：open 时表双份加载

`LevelsController.init`（levels.cj:32-35）与 `Badger.open`（badger.cj:103-106）**各调用一次 `loadTables()`** → manifest 中每张表被 `addTable` 两次。所有 reopen 均如此：内存翻倍，compaction/迭代器多一份重复表。

### 3.4 写盘结果检查缺失（issue §4.2，加剧数据丢失面）

| 位置 | 问题 |
|---|---|
| badger.cj:362 `flushMemTablesBatch` | `writeFilesBatch(...)` 返回 `ArrayList<FileWriteResult>` **完全未检查**；io_uring 失败/缺结果时静默 |
| badger.cj:401 `flushMemTableToDisk` | `writeFile` 返回值未检查 |
| file_io.cj:25-39 `writeFile` | **恒返回 `data.size`**（写失败不体现在返回值，仅靠异常传播）→ "检查返回值"形同虚设 |
| io_uring_pool.cj:146-157 | CQE 获取 `ret < 0` 时 `break`，未完成 op **不进 results** → 批量调用方（即使检查）也拿不到完整结果 |

### 3.5 顺带发现（建议另案/同批处理）

- compaction.cj:295 `compactBuildTables` 用 **`db.getVersion()`（提交版本号）作 tableId**：与 `nextFileID` 文件序列是两套计数器 → 表 id 与 flush/close 路径的 id 可能重叠；同版本号期间多次 compaction 会**覆写同一 id 文件** + manifest 同 id 双记录（deleteTables 按 id 删除时有误删风险）→ 需改为 `nextFileID.fetchAdd`
- compaction.cj:297 `writeFile` 返回值同样未检查（异常会杀死 compactor 协程，spawn 内无兜底）
- flushToLevel（运行期）与 flushMemTableToDisk（close）对事务标记（`isFinTxn`/`clearTxnMarks`）处理不一致（badger.cj:386-391 vs 602-605）

## 4. 修复方案

### F1（主修复，对应 R1）：运行期 flush 落盘 + imm 生命周期收口

改动集中在 `badger.cj`（`flushMemTableInternal`/`flushToLevel`/`close`）：

1. `flushToLevel` 增加落盘：构建 SSTable 后（非 InMemory）`writeFile(sstablePath, data, useIoUring: opt.UseIoUring)`（已具备 io_uring 降级）→ **检查写盘结果，失败即抛异常**（走既有 P1-2 失败必报链路：`putPrepared` → pipeline `markFailed` → `batchSet` 报错，绝不静默成功）→ 成功后 `lc.addTable(0, TableAdapter(table))` + `manifestFile.saveChanges(Create, level 0)`
2. **写盘+MANIFEST 成功后才允许删 WAL**（`decrRef` 移到成功路径末尾；失败时表留在 imm、WAL 保留，崩溃可重放）
3. flush 表落盘成功后**从 imm 移除该表**（写锁内，读锁互斥安全；数据已持久 + L0 内存表仍服务读）→ close 时 `allTables` 只剩「open 遗留 replay 表 + 当前 mt」，**消除 close 重复落盘**（当前若 flush 已落盘而 imm 不清，close 会把同批数据写第二遍 + manifest 双记录）
4. flushToLevel 事务标记处理与 flushMemTableToDisk 对齐（skip `isFinTxn` + `clearTxnMarks`），避免两路径行为分叉
5. L0 内存表保留（读性能设计不变）；内存增长源由"每 flush 双份无限增长"收敛为"L0 表 ≤ NumLevelZeroTables 触发 compaction 回落"（compaction 已把 L0 全压 L1 并清 L0，见 compaction.cj:240-262）

> 说明：表数据全量驻留内存是该移植的既有架构（loadTables 全量 readFrom，运行期表为内存对象），修复后内存=各层内存表总和而非无限双份增长；低频大容量场景若仍超堆上限，属架构演进范畴（mmap/表缓存化，v2.0 路线图），不在本修复范围。

### F2（必配，对应 R3）：磁盘表 seek 定位修复

`table.cj findBlock`（或 TableAdapter 读路径）修复块定位：二分结束后若 `key < 块首` 且 key 与块首**属于同一 user key**（parseKey 后相等，即 seek 版本 ≥ 组内最大存储版本的情形），应返回该块（组内第一个 ts ≤ readTs 的版本 = 组首）而非回退 `left - 1`。配套排查所有经 `findBlock`+seek 的读路径调用点：`TableAdapter.get`、`LevelHandler.getL1Plus`、iterator/scan/stream 的 seek 语义（验证清单见 §6）。

### F3（对应 R2）：去除 open 双载

`LevelsController.init` 或 `Badger.open` 二选一调用 `loadTables()`（建议保留 open 处显式调用、init 内删除，或反之——以最小 diff 为准），补 reopen 表数断言测试。

### F4（防御，对应 §3.4）：写盘结果全链路检查

1. `flushMemTablesBatch`：遍历 `writeFilesBatch` 返回的 results，任一 `success == false` 即抛异常（含 io_uring 缺结果：results 数 < requests 数也视为失败）
2. `writeFile` 失败语义明确：写失败必须抛异常（异常传播已有），返回值仅作字节数参考；或在 file_io 内改为真实写入字节 + 调用方检查（二选一，建议前者保持小 diff）
3. `io_uring_pool.doWriteFiles`：CQE 循环中断时把未完成 op 补记为失败结果，保证返回项数与请求项数一致
4. compaction.cj:297 写盘结果检查并入本批

### F5（建议）：compaction 文件 id 修正 + 文档

1. compaction.cj:295 `tableId = db.getVersion()` → 统一走 `nextFileID` 序列（与 flush/close 一致）
2. README/progress 提示：容器默认 256MB GC 堆上限下，全内存表架构建议按数据量配置 `MemTableSize`/堆上限

### 跨仓库联动（不属 badger-cj 提交）

- json-rpc `receiveLoop`/handler 边界只 catch `Exception`，`OutOfMemoryError`（Error）逃逸杀协程（jsonrpc/src/server.cj:216-235）→ 建议独立工单评估服务边界对 `Error` 的兜底或 OOM 前置预防（GC 堆配置/节流）
- chronomem 生产配置：修复 F1 前避免长跑不重启；修复后需验证重启读（F2）与 GC 堆余量

## 5. 验证计划

1. **回归测试**（本报告同批交付，`flush_persist_regression_test.cj`）：
   - `testRuntimeFlushShouldWriteSstAndManifest`：≥2 次 flush 后 `.sst > 0`、MANIFEST > 0（F1）
   - `testCloseFlushPersistsAndReopenReadsAll`：同步/io_uring 双配置 close→reopen 160/160（F1+F2+F4）
2. **新增用例**（修复时补）：reopen 后 `db.tables()` 表数 == manifest 表数（F3）；imm 移除后 `getMemTables()` 只含当前 mt（F1）
3. **全量回归**：`cjpm test -j 16 --no-progress`（336+ 用例，尤其 persistence/levels/compaction/iterator/stream/crash_recovery）
4. **crash 语义**：扩 `crash_recovery_test`——写满 flush（不 close）后 kill -9 → 重启数据完整（F1 落盘 + WAL 重放）；对照组（修复前）预期丢已 flush 数据
5. **e2e**：`src/examples/graceful_exit` + `scripts/graceful_shutdown_e2e.sh`；默认 seccomp 容器（io_uring 被禁）复跑对照
6. **compaction 联动**：默认 `NumLevelZeroTables=4` 持续写入 → L0→L1 compaction 落盘后重启一致性

## 6. 建议修复顺序

1. 开分支 `fix/flush-persist`（master 当前 HEAD `29507fd`），先提交 F1 主修复 + 回归用例
2. 同批提交 F2（R3 seek 修复）——**必须与 F1 同批发布**，否则 F1 上线后重启即丢读
3. F3/F4 防御同批或紧随（小 diff）
4. F5 与 compaction id 修正另案验证后提交
5. 发布前按 §5 跑全量 + 容器对照

## 附录 A：badger-go 落盘点 vs badger-cj 缺口（对齐语义基线）

对照源码：`~/Projects/badger`（v4 参考版，HEAD 796cb85）。go 的持久化契约：**「写 = vlog/WAL 已落盘；flush = L0 SSTable 已落盘 + memtable 即释放」**，运行期/Close 共用同一套 flush 落盘函数（`handleMemTableFlush`，db.go:1063）。

| # | go 落盘点 | 触发 | go 实现 | cj 现状 | 缺口 |
|---|---|---|---|---|---|
| 1 | Value Log（大值/需日志 entry） | 每次写请求 | `vlog.write(reqs)`（db.go:840），小值 `skipVlogAndSetThreshold` 跳过 | vlog 有（无动态阈值） | — |
| 2 | MemTable WAL | 小值写 skiplist 同步追加 | `mt.wal.writeEntry`（memtable.go:183），flush 成功 refcount 归零删 WAL | `.mem` WAL 有 | — |
| 3 | **memtable flush → L0 SSTable + manifest** | ① mt 满 `ensureRoomForWrite` 推 flushChan ② open 遗留 imm ③ Close 排空 | **唯一 flush 实现** `handleMemTableFlush`：`table.CreateTable` → `addLevel0Table`（**先 manifest 后挂 L0**，levels.go:1559-1573） | 运行期 `flushToLevel` 纯内存（badger.cj:598-617）；close 走另一套 `flushMemTableToDisk`/`flushMemTablesBatch` | **①主缺口（R1）②③ 均缺** |
| 4 | flush 后 memtable 出队释放 | flush 成功 | 单 flusher `imm=imm[1:]` + `DecrRef`（db.go:1118） | imm 只增不减（仅 close clear） | **缺（R1 内存侧）** |
| 5 | flush 失败重试 | 写盘/ manifest 失败 | 记日志 + sleep 1s **无限重试**（db.go:1105-1108），绝不静默 | 运行期无写盘无失败可言；close/compaction 写盘结果不检查 | **缺（F4）** |
| 6 | compaction 写盘 | L0 数/层大小超阈值（compactor 多 goroutine） | `compactBuildTables`（levels.go:868）每 split `CreateTable` + manifest Delete/Create；文件 id 统一 `reserveFileID` | compaction.cj 有写盘；id 误用 `db.getVersion()`；结果不查；无分片 | **部分（F4/F5）** |
| 7 | manifest | 表增删 | `addChanges` 追加 + 超阈值 rewrite 压缩 | append-only，无 rewrite | 次要，另案 |
| 8 | 表文件 mmap | 创建/加载 | `table.Open`/`CreateTable` → mmap，不占 GC 堆 | Table 全量 `Array<Byte>` 驻留堆 | **架构级（v2.0 mmap 路线）** |

### 对齐实施范围（fix/flush-persist）

- **F1 对齐 #3/#4**：`flushToLevel` 恢复 go 原语——写 SSTable（io_uring 降级）→ **先 saveChanges 再挂 L0** → imm 出队 + `DecrRef`（删 WAL）；与 close 路径共用事务标记清理；open 遗留 imm 立即落盘（对齐 #3-②）
- **F2**：磁盘表 seek 定位修复（R3，重启读旧表数据）
- **F3**：loadTables 双载（LevelsController.init 与 open 各一次）→ 保留 init、删 open
- **F4 对齐 #5**：close 批量/单表写盘结果检查、compaction 写盘结果检查 + compactor 循环防护（失败记录不杀协程）
- **F5 对齐 #6**：compaction 文件 id 改统一 `reserveFileID`
- **暂不对齐**：#8 mmap（v2.0）；go 的 flush 异步化（flusher 线程）列 P2-2 后续优化项——本次 flush 仍在写锁内同步，先保证正确性
