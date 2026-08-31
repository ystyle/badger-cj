# 评审报告：write-fail-loud（写入失败必报）

- **日期**：2026-08-30
- **分支**：`fix/write-fail-loud`（基础 `master` @ 2c34212）
- **变更范围**：`src/db/badger.cj`、`src/db/transaction.cj`、`src/db/write_pipeline.cj`、`src/db/write_request.cj`、`src/db/large_batch_test.cj`（新增）
- **验证**：`cjpm test --filter 'LargeBatchTest.*' --show-all-output -j 16` → **2/2 PASSED**（编译通过，项目其余用例不受影响）

---

## 一、修改意图（从 diff 注释还原）

1. **修复静默丢数据**：`WritePipeline` 旧实现 `catch` 吞掉 `handler` 异常后仅 `req.done()`，`commit()` 无条件返回 `Ok`——arena 溢出（单事务条目数超过 memtable 容量）、value 超 64KB 编码上限都会"写失败却返回成功"。
2. **对齐 badger-go**：`request.done(err)` / `txn.Commit` 失败返回 `Err` 的语义，改为 fail-loud。
3. **顺带修复**：原 `writeRequests` 中 `mt.put` 在写锁外执行，与用户显式 `flushMemTable()`（持写锁换 `mt`）存在竞态；本次改为整批持写锁。

## 二、结论摘要

**方向正确、核心链路已修复、测试通过，可以继续推进；但 fail-loud 目标未完全达成，存在 2 个 P1 缺口（WAL 残留失败数据、batchSet 路径未覆盖）与 2 个 P2 问题（drain 路径无错误传播、写锁内行 I/O），建议按本报告补齐后再提交。**

---

## 三、合理之处（评审通过的部分）

| 项 | 说明 |
|---|---|
| `runBatch` 错误传播结构 | `try { handler } catch { markFailed }` + 统一 `done()`，对齐 badger-go `writeRequests` 的 `req.done(err)` 语义；无论成败都保证 `req.done()`，`wait()` 不会悬挂。 |
| `WriteRequest.markFailed/errorOf` | 首次失败保留、后续不覆盖；`reset()` 中清空，池复用前状态干净；`markFailed` 发生在 `done()` 之前，配合 `SyncCounter`（锁/条件变量实现）`wait()` 返回后存在 happens-before，读写可见性成立。 |
| `commit()` 失败路径 | `oracle.doneCommit` + `reqPool.put` + `committed = true`，与成功路径资源回收完全一致，没有引入泄漏或重复 put。 |
| 条目级 `shouldFlush` 检查 | 对齐 badger-go `ensureRoomForWrite` 语义——单 req 可含大量条目（批量物化/大事务），只检查一次必然 arena 耗尽；这是对根因的正确修复。 |
| 整批持写锁 + `mt.put` 入锁 | 修复了原 `writeRequests` 中 `mt.put` 无锁与 `flushMemTable()`（持写锁换 `mt`）并发导致的"写入已淘汰 memtable"竞态；读持读锁、写持写锁的互斥关系正确。 |
| 新增测试 | 两个回归场景（大事务触发多轮 flush、超限值 fail-loud）合理；`testOversizeValueFailLoud` 还断言了失败后库仍可写入，符合"库不被污染"的验收。 |

---

## 四、问题清单（按严重性排序）

### P1-1：失败事务数据残留 WAL，崩溃恢复后"复活"（修复目标 2 的盲区）

`MemTable.put()`（`src/db/memtable.cj:57-84`）的执行顺序：

```cangjie
let encoded = vs.encode()              // ① 编码：不检查 64KB 上限（varint 无截断）
if (!opt.DisableWAL && ...) { w.write(key, encoded) }  // ② WAL 已写入！
if (encoded.size > 65535) { throw ... }   // ③ 64KB 检查在 WAL 之后
let offset = arena.putBytes(encoded)      // ④ arena 溢出检查也在 WAL 之后
```

以测试 2 的 70KB value 为例：① 编码成功 → ② **WAL 已写入 70KB** → ③ 抛异常。本次改动让 `commit()` 正确返回 `TxnStatus.Error`（改对了），但：

- **进程崩溃（不走 `close()`）后重启**，WAL replay 会把这条"失败事务"的数据重新放回 memtable；
- 读路径（`badger.cj:330-361`）不检查 `bitTxn/bitFinTxn` 标记，replay 后数据**直接可见**——调用方收到失败却可能在重启后读到该数据，与"失败必报"语义矛盾。

**建议**：将 64KB 上限检查提前到 encode / WAL 之前（理想在 `writeRequests` 循环里直接检查 `entry.value.size + 编码开销`，或 `memtable.put` 第一步）；arena 剩余空间也可在写 WAL 前预检。**补充测试**：失败后不 `close()`（同一进程内直接重开新实例 replay 同目录 WAL，或模拟崩溃），断言该 key 不可见。

### P1-2：`batchSet` / `batchSetAsync` 路径未覆盖错误传播

`badger.cj:363-398` 的 `batchSet`/`batchSetAsync` 同样走 `writeCh → req.wait()`，但**没有检查 `req.errorOf()`**——大 value / arena 溢出时仍然静默丢数据（本次修复前的问题在这条路径原样存在）。

**建议**：`batchSet` 在 `wait()` 后检查 `errorOf()` 并抛异常（或改签名返回错误）；`batchSetAsync` 在回调线程检查后上报。补对应单测。

### P2-1：drain 路径（`writeOneRequest`）无错误传播，且代码重复

`flushLoop` 关闭时的 drain（`badger.cj:509-513`）调用 `writeOneRequest`，该路径：
- 抛异常时**逃逸到 `flushFut` spawn 线程**（`f.get()` 时爆出，`db.close()` 可能抛异常）；
- 不 `markFailed` → 已入队事务 `wait()` 返回后 `errorOf() == None` → 仍"假装成功"。

且 `writeOneRequest` 与 `writeRequests` 内层循环几乎一致。

**建议**：合并为单一路径——`writeOneRequest` 内部 `try { ... } catch (e: Exception) { req.markFailed(e.message) } finally { req.done() }`，或让 drain 也复用 `runBatch`。

### P2-2：写锁内持有磁盘 I/O（性能回归，读延迟受影响）

本次把 `vlog.write`（`VLogManager.write` 有自身 `Mutex`，且 `VLogFile.write` 是无缓冲的 `File.write`，**每条目一次 syscall**）与 flush 时的同步 SSTable 构建（`flushToLevel`：`TableBuilder` + `finish` + `lc.addTable`）全部移入全局写锁：

- 读线程（持 `readLock`）会在整批写入 + flush 期间被完全阻塞；
- 大事务（如测试 1 的 5000 条）触发多轮 flush，锁持有时间 = 多轮 SSTable 编码 + 全部 vlog syscall；
- badger-go 中 `flushMemtable` 只做检查 + 交给后台 flush 线程，vlog 有自己的锁，`mt.Put` 是原子 skiplist 插入，均不持全局写锁。

**合理部分**：`mt.put` 与 `imm/mt` 交换（`flushMemTableInternal`）必须在写锁内——否则读线程在 put/flush 中途读到不一致的 memtable 集合。
**建议**：把 `vlog.write` 移出写锁（pipeline 单线程 + `VLogManager` 自有锁，顺序天然一致；异常时该条目 vlog 孤儿由 VLog GC 回收，与重试语义兼容）；`flushToLevel` 的同步构建若短期不改异步化，至少在注释/文档中说明该设计约束。

### P2-3：`catch (e: Exception)` 覆盖范围

仓颉异常体系分 `Error`（运行时内部错误/资源耗尽，不可自定义）与 `Exception`（应用/IO 逻辑错误）两类，`catch (e: Exception)` **不会捕获 `Error`**。若 `handler` 抛 `Error`（如内存耗尽），`req.done()` 不执行 → 事务线程 `wait()` **永久悬挂**，且 `db.close()` 的 `f.get()` 会把 `Error` 再次抛出。

**建议**：改为 `try/catch/finally`，把 `done()` 放进 `finally`（保证不悬挂），`catch` 中 `markFailed`；`Error` 至少不悬挂，虽有残留但不至于死锁。

### P3-1：失败批的"部分已写入"语义（可接受，需文档化）

`handler` 抛异常时，批内**之前已完成**的条目/请求数据已进入 memtable/vlog，但被整体 `markFailed`。调用方重试会写入新 `commitTs` 版本，旧版本按 `readTs` 过滤不可见，作为孤儿数据直到 compaction 清理。badger-go 语义相同，可接受；建议在 `runBatch`/`commit` 注释中明确"失败不等于零写入"。

### P3-2：小事

- `write_pipeline.cj`、`write_request.cj` 文件尾缺换行（diff 提示 `No newline at end of file`）。
- `transaction.cj` 失败/成功路径重复 3 行（`doneCommit + reqPool.put + committed = true`），可提取公共尾部。
- `large_batch_test.cj` 使用固定目录 `/tmp/badger_large_batch_test`：与其他测试命名无冲突、类内自清理，可接受；与项目多数测试（`${hash}` 后缀）风格不一致，属可选项。
- `testLargeBatchSurvivesMemtableFlush` 只断言 `isSome()` 未校验 value 内容——对"丢数据"回归已足够，如需更强可校验内容。

---

## 五、修改后必须补充的测试（TDD 补丁）

1. **WAL 残留回归**（对应 P1-1）：70KB 失败写入 → 不 close，重开同目录实例（WAL replay）→ 断言该 key 不可见。
2. **batchSet 失败路径**（对应 P1-2）：`batchSet` 大 value/超量条目 → 断言抛异常（或返回错误），且之后库可用。
3. **drain 路径**（对应 P2-1）较难在单测直接触达（需先 close writeCh），可在 `Db.close` 顺序上验证：close 前入队一个超限值 req → close 不抛异常且对应回调收到失败标记。若实现成本高，至少保证 P2-1 的合并后单测覆盖 `writeOneRequest` 的失败分支。
4. **大 value 走 vlog 路径**（`ValueThreshold=1MB`）目前无失败测试：value 略超 64KB 而 `< Threshold` 的边界值建议一并补充（64KB 上限是 `ValueStruct` 编码限制，与 ValueThreshold 解耦，应显式测试）。

## 六、修改建议汇总（按优先级）

| # | 优先级 | 动作 |
|---|---|---|
| 1 | P1 | 64KB 上限检查提前到 WAL 之前；新增 WAL 残留回归测试 |
| 2 | P1 | `batchSet`/`batchSetAsync` 增加 `errorOf` 检查与上报；补单测 |
| 3 | P2 | 合并 `writeOneRequest`/`writeRequests` 错误处理路径，drain 也 fail-loud |
| 4 | P2 | `vlog.write` 移出全局写锁；评估 flush 同步构建的锁内开销 |
| 5 | P2 | `runBatch` 改 `try/catch/finally`，`done()` 放入 `finally` 防 `Error` 悬挂 |
| 6 | P3 | 文件尾换行、失败路径去重、注释"失败≠零写入"语义说明 |

> 建议完成 P1 两项后先行提交（含单测），P2 项作为后续优化项排期；按项目约定「有单元测试后再提交」。

---

# 复审（2026-08-31，基于提交 `40311bf`）

> 其它会话基于初评审完成实现并提交 `40311bf fix: 写入失败必报 + WAL 重放容错 + oracle 冲突语义对齐 badger-go`。本复审针对该提交相对 `master`(2c34212) 的完整 diff，并复跑全量测试。

## 验证情况

- `cjpm test -j 16 --no-progress` → **329/329 PASSED**（含新增 LargeBatchTest 3 用例、TxnConflictSemanticsTest 2 用例、OracleTest 时序修正）。

## 一、上一轮问题处理情况

| 项 | 处理 | 说明 |
|---|---|---|
| P1-1 WAL 残留失败数据 | ✅ **根治 + 兼容** | ① `MemTable.put` 把 64KB/arena 预检提前到 WAL 之前（`encoded.size > 65535` 与 `remaining` 预检均在 `w.write` 前），新写入不再产生残留——预检精确：`putBytes` 走 `allocate` 无对齐开销，剩余空间判断与实际消耗一致；② `WAL.replay` 对坏条目 try/catch 跳过，兼容旧版已残留数据（112KB 桶记录）启动不崩。新增 `testWalReplaySkipsOversizeFailedTxn` 覆盖。 |
| P1-2 batchSet 静默失败 | ✅（batchSet）/ ⚠️（batchSetAsync 半修复） | `batchSet` wait 后检查 `errorOf` 并 `throw Exception`（先还池再抛，顺序正确）；`batchSetAsync` 仅在回调线程 `println` 上报——错误不经过 callback，无编程错误通道，建议文档化或后续改签名。 |
| P2-3 Error 不捕获 → wait 悬挂 | ✅ | `runBatch` 改 `try / catch(Exception) / catch(Error) / finally(done)`，`done()` 入 finally，任意异常类型都不悬挂；`catch(Error)` 编译通过，仓颉允许按具体类型捕获。 |
| P2-1 drain 路径无错误传播 + 代码重复 | ❌ **未处理** | `writeOneRequest` 仍只有 `try/finally`（unlock + done），无 `markFailed`；异常仍会逃逸到 `flushFut` spawn 线程，close 期间已入队请求失败时调用方仍"假装成功"。与 `writeRequests` 内层循环完全重复。 |
| P2-2 写锁内磁盘 I/O | ❌ **未处理** | `vlog.write`（无缓冲 `File.write` syscall）与 flush 时同步构建 SSTable 仍在全局写锁内；条目级 flush 使大事务触发多轮 flush，读延迟影响面比旧版更大。 |
| P3 文件尾缺换行 | ❌ 未处理 | `write_pipeline.cj`、`write_request.cj` 尾部仍无换行（`No newline at end of file`）。 |

## 二、新增 oracle 冲突语义修改的评审（重点）

**修改目标**（提交说明）：① `hasConflict` 无 readTs 门槛 → 顺序事务"读旧版重写"必误判 `TxnConflict`（物化幂等重写第二次必炸——"桶点不开"根因）；② 纯写事务不入册 → 真实写-写交错检测不到（此前压测用 95% 容忍掩盖）。

**逐点核验（均通过）**：

1. **hasConflict 加 readTs 门槛**（`committedTxn.ts <= txn.readTs → continue`）：快照语义正确——readTs 之前提交的写已包含在本事务读快照中，不构成冲突；readTs 之后提交的写不在快照中，必须冲突。对齐 badger-go `oracle.go` 的 `hasConflict`（`if t.ts <= readTs { continue }`）。手工推演：顺序重写（T2 readTs=1，T1 commitTs=1 → 1≤1 不冲突 ✅）、并发交错（txnB commitTs=2 > txnA readTs=1 → 冲突 ✅），与 `TxnConflictSemanticsTest` 两用例一致。
2. **纯写事务也登记 committedTxns**（`detectConflicts && !conflictKeys.isEmpty()`）：写-写交错可检测 ✅；写事务必有 conflictKeys（set/delete 均 addConflictKey），登记覆盖完整。
3. **所有事务统一 `doneReadInternal(txn)`**：修复了原快速路径（无 reads 纯写事务）readMark 永不 done 的泄漏——readMark 不推进则 `cleanupCommittedTransactions` 永远清理不掉 committedTxns（这正是 10 万兜底 trim 出现的原因，两处逻辑自洽）。`Transaction.discard()` 的二次 `doneRead` 无害：`WaterMark.done` 幂等（HashSet.remove 不存在元素无操作）。
4. **cleanup 保留窗口**（`txn.ts > maxReadTs`）：活跃事务 readTs=X 未 done ⇒ `doneUntil ≤ X-1` ⇒ 保留集合 ⊇ {ts ≥ X}，冲突检测所需（ts > X）必被保留，**不漏检** ✅。
5. **10 万兜底 trim**（保留最近 5 万）：仅在 cleanup 失效（无读事务、readMark 不推进）时防无限增长。边缘风险：极长事务（readTs 很旧）在 10 万+ 次提交后才提交，trim 可能丢弃其冲突信息导致漏检——但此场景下无 reads 推进意味着也没有冲突检测需求方，实际影响趋近于零，作为低风险提示记录。
6. **oracle_test 时序修正**：`txn2` 创建（readTs 分配）移到 `txn1` commit 之前，使 `txn2.readTs < txn1.commitTs` → 冲突检测条件成立，测试语义修正正确。
7. **managed 分支**：`hasConflict` 门槛同样生效；managed 事务 readTs 由外部传入，行为未变差。

## 三、新发现问题

| # | 级别 | 问题 | 建议 |
|---|---|---|---|
| 1 | P2 | **WAL replay 半截事务复活**：replay 恢复事务条目时逐条 try/catch，同事务其它条目照常恢复 → 失败事务的部分数据复活（与 fail-loud 语义矛盾）。注意新版本预检保证不再产生新残留，此路径仅影响旧版遗留数据——属"缓解非根治"。且 catch 无日志，排障困难。 | 整事务原子恢复：任一坏条目 → 丢弃整个 pendingTxnEntries（直到 finTxn 为止不恢复该事务）；catch 中 println/计数。 |
| 2 | P2 | **drain 路径错误传播缺失**（P2-1 遗留）：`writeOneRequest` 无 `markFailed`，close 期间已入队请求失败仍"假装成功"。 | 与 `writeRequests` 合并或加 catch+markFailed。 |
| 3 | P2 | **写锁内磁盘 I/O**（P2-2 遗留）：`vlog.write` syscall + 同步 SSTable 构建。 | `vlog.write` 移出写锁（VLogManager 自有锁 + pipeline 单线程）；flush 异步化排期。 |
| 4 | P3 | batchSetAsync 错误仅日志不进 callback | 文档化或改签名（如 `?(Result)->Unit`）。 |
| 5 | P3 | 文件尾缺换行（两文件） | 补换行。 |
| 6 | P3 | 10 万 trim 边缘漏检 | 保持现状即可，注释说明取舍。 |

## 四、复审结论

**✅ 通过，可以合入 master。**

- 上一轮全部 P1（WAL 残留、batchSet 静默失败）已修复且有对应单测；P2-3 悬挂问题已修复。
- 新增 oracle 冲突语义修改方向正确、与 badger-go 对齐、测试充分（顺序不误判 + 并发仍检测 + OracleTest 时序修正），是"桶点不开"根因的真实修复。
- 剩余项均为 P2/P3：drain 路径错误传播、写锁内 I/O（可排期优化）、WAL replay 半截事务（仅旧数据路径，可后续加固）、代码风格小事。
- 建议：合入 master 后，把 P2 项登记为后续优化；若追求一次到位，可在合入前补 drain 路径与 replay 整事务丢弃两处小改（各配一个单测）。

---

# 终审状态（2026-08-31 晚，问题全部闭环）

> 按用户要求补齐剩余项，逐项终审：

| 评审项 | 状态 | 处理 |
|---|---|---|
| P1-1 WAL 残留失败数据 | ✅ 闭环 | 40311bf：64KB/arena 预检提前到 WAL 前 + replay 容错 + 测试 |
| P1-2 batchSet 静默失败 | ✅ 闭环 | 40311bf：batchSet throw |
| P1-2 batchSetAsync 错误通道 | ✅ 闭环 | 5290b2c 后半 + 本次：签名改 `callback!: ?((?String) -> Unit) = None`（None=成功/Some(msg)=失败，经 callback 上报，未传时日志兜底）；新增 testBatchSetAsyncErrorChannel |
| P2-1 drain 错误传播 + 代码重复 | ✅ 闭环 | 5290b2c：writeOneRequest markFailed + 合并 prepare/put |
| P2-2 vlog 移出写锁 | ✅ 闭环 | 5290b2c：两阶段 prepare→put |
| P2-2 flush 同步构建 | ✅ 决策闭环（不做） | 评估结论：当前"imm 保留 + L0 内存冗余"保证刚写入数据内存读；异步化会引入读性能回退（L0 磁盘表无缓存）且需重构 close 写盘联动，收益风险不成比例。已在 flushMemTableInternal 注释记录为设计约束，异步化列未来优化项 |
| P2-3 Error 不捕获悬挂 | ✅ 闭环 | 40311bf：catch(Error) + finally done |
| P2-3(复审) replay 半截事务 | ✅ 闭环 | 5290b2c：整事务原子恢复 + 测试 |
| P3 换行 | ✅ 闭环 | 5290b2c |
| P3 失败≠零写入注释 | ✅ 闭环 | runBatch 注释 |
| P3 transaction.cj 失败/成功路径去重 | ✅ 闭环 | 本次：提取统一收尾（errOpt 先读 → doneCommit/put/committed → match 返回） |
| P3 10 万 trim 边缘漏检 | ✅ 决策闭环（接受） | 低风险兜底，注释说明取舍 |
| P3 测试 value 校验 | ✅ 决策闭环（可选加强） | 对"丢数据"回归已足够 |

**结论：评审报告全部问题均已闭环（修复或明确决策），无遗留。**
