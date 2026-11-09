# 异步 Flusher + TableBuilder 单拷贝（L1）设计

> 状态：**主体已实现**（v1.6.17，分支 feat/async-flusher；实现记录见 progress-tracking
> 的 v1.6.17 行与 v1.6.17-fix2 行）。本设计两件事都已合入：① flush 移出全局写锁、单 flusher
> 协程锁外执行（实现于 src/db/badger.cj 的 flushQueue/rotateAndEnqueueLocked/waitForFlushRoom/
> persistMemTable，测试 src/db/async_flusher_test.cj）；② TableBuilder L1 单拷贝（分块持有 +
> finish 一次拼接，见 src/table/builder.cj）。**L2（块完成即写文件的真流式落盘）未做**，
> 即「背景与动机」注释里说的另行排期项；2.0 的 compaction 输出/备份已改为流式，但普通
> flush 的 builder 仍是整表驻留。

> 2026-09-05 · 对应分支 `feat/async-flusher`（异步化）+ 同一分支内 L1 builder 改造
> 关联：v1.6.12 flush 落盘语义（#520）、评审 P2-2 遗留（#518「flush 同步 SSTable 构建仍在
> 全局写锁内」）、chronomem OOM 事故链（#524）、go 锚点 `~/Projects/badger`。

## 背景与动机

### 现状缺陷 1：flush 在全局写锁内同步执行

`putPrepared`（badger.cj:788）条目级检查 `mt.shouldFlush()` → `flushMemTableInternal()`
在**写锁内完整执行**（迭代 memtable → TableBuilder 构建 → 压缩 → 落盘 → MANIFEST →
lc.addTable → imm 出队）。后果：

- flush 期间（大表可到百毫秒级）所有读者（持读锁）与后续写者全停——写/读延迟尖刺；
- 锁内做磁盘 I/O + 压缩 CPU 密集工作，把「一次 flush 的错误」与写路径耦合
  （OOM/Error 连锁曾杀 WritePipeline 协程，见 #524）；
- 与 badger-go 架构偏离：go 的 `flushMemtable` 是独立 goroutine（db.go:1097），
  `ensureRoomForWrite`（db.go:1010）锁内只做**短暂轮换**，`handleMemTableFlush`
  （db.go:1063）全程锁外，失败无限重试。

### 现状缺陷 2：TableBuilder 整表双份驻留 + 逐字节累积

`flushToLevel` 构建链（builder.cj）：

1. 每块 finish 后压缩结果**逐字节** `add` 进 `buf: ArrayList<Byte>`（低效扩容搬运）；
2. `finish()` 再 `buf.toArray()` 产生**整表第二份连续拷贝**；
3. 构建期与 memtable（arena = 2×MemTableSize）并存 → flush 峰值 ≈ arena + 2×表。

对比 go：builder 块级持有（`buildData.blockList`，各块独立分配），`CreateTable` 时
`bd.Copy(mf.Data)` **一次拷贝**进 mmap 文件（builder.go `buildData.Copy`）。

> 注：L1 只做「去双拷贝 + 去逐字节累积」（分块持有，finish 一次拼接为唯一一份
> 连续数据）。真流式落盘（块完成即写文件、不驻留整表）为 L2，牵动磁盘表数据源
> （现 `Table(tableID, data)` 直接持有构建产物）与 io_uring 分段写，另行排期。

## 目标（本分支）

1. **flush 异步化**：写锁内只轮换 memtable；构建+压缩+落盘+MANIFEST+addTable 全部
   移出写锁，由单一 flusher 协程串行执行；完成后锁内短临界区出队 + decrRef。
   对齐 go：失败重试不丢表；队列深度上限形成背压；close 时序重排无死锁。
2. **TableBuilder L1**：分块持有 + 一次性拼接；文件格式位级不变（读路径零改动）；
   flush / compaction / close 三处建表调用方零改动受益。
3. Config 对齐 go 增加 `NumMemtables`（默认 5，go WithNumMemtables 默认），
   「内存中未落盘 memtable 上限，超出则写入停顿」。

## 设计

### A. 数据流与角色

```
写入路径(单 worker pipeline 或 flushMemTable API)
  │  锁内: rotateMemTableLocked()          ── imm.add(mt) / mt=新建 / immCount++
  ▼
flushQueue: CloseableBlockingQueue<MemTable>(cap = NumMemtables)
  │  锁外 add（队列满 → 阻塞 = 背压；flusher 腾位后继续）
  ▼
flusher 协程（单实例，串行）
  │  锁外: 构建表 → 落盘 .sst → MANIFEST saveChanges → lc.addTable(0)
  │  （失败: catch(Exception)→重试 sleep 1s；catch(Error)→记录后继续，协程永存）
  ▼
完成段（锁内短临界区）: imm 中定位该表 remove + decrRef + immCount-- + 唤醒等待者
```

关键不变量：

- **imm 集合的变更（add/remove）一律在 db 写锁内**——读路径在读锁内遍历 imm，
  此互斥不变量保持不变（现状 flushToLevel 出队也在写锁内，安全模型不扩大）；
- 表「逻辑出队」（读不可见）严格发生在落盘 + addTable **之后**——不存在
  「已从 imm 摘除但磁盘表不可读」的窗口；
- flusher 与写路径对 imm 的操作互斥但处理顺序解耦：出队按**对象定位**而非
  假定 FIFO（并发 flushMemTable 可能与 pipeline 轮换交错入队）。

### B. 轮换（写锁内，取代 flushMemTableInternal 的锁内全量 flush）

```cangjie
// 返回被轮换出的旧表（由调用方在锁外入队）
private func rotateMemTableLocked(): MemTable {
    let old = mt
    imm.add(old)                  // 读写互斥不变量
    immCount.fetchAdd(1)
    mt = MemTable(opt, Int64(reserveFileID()), !opt.InMemory)
    old
}
```

调用点：

1. `putPrepared`（写路径）：条目循环内 `if (mt.shouldFlush())` → 先背压检查
   （见 C）→ 轮换 → **锁外** `flushQueue.add(old)` 后再继续 put。实现为条目
   循环的嵌套锁段：锁内循环 put 直到 shouldFlush；解锁入队；重锁继续。
2. `flushMemTable()` 公开 API（同步语义）：轮换 + 锁外入队 + 等待该表落盘完成
   （水位等待：immCount 回到轮换前水位，见 D）。
3. open 恢复遗留 imm：保持同步 flush（flusher 尚未启动，直接调完成段同步版本）。

### C. 背压（队列满 → 写入停顿，对齐 go errNoRoom）

- 队列容量 = `opt.NumMemtables`（默认 5）；
- rotate 前置检查：若 `immCount >= opt.NumMemtables` → **解锁写锁**，等待
  flush 进度 Condition（immCount 下降）→ 重入重试。绝不持写锁等待 flusher
  （flusher 完成段需要写锁，持锁等待即死锁）；
- 等待原语：`flushCondMutex + Condition`（std.sync，先例 CloseableBlockingQueue），
  flusher 每完成一张表 `notifyAll`；等待循环统一收口在
  `waitImmBelowLocked(limit)`（内部先解锁、等待、再重入）。

### D. 完成段与等待语义

```cangjie
// 锁外：构建 + 落盘 + manifest + addTable；失败抛（调用方重试策略处理）
private func flushOne(mt: MemTable): Unit

// 锁内：从 imm 按对象移除 + decrRef + 计数减一 + notify
private func finishFlushLocked(mt: MemTable): Unit
```

- flusher 主循环：`while (running || flushQueue.size() > 0)` → remove（阻塞）→
  try flushOne catch → 失败重试（Exception: sleep 1s；!running 时放弃留表给 close
  兜底；Error: 记录，继续循环保活——OOM 不再杀 flush 链路）；
- flushMemTable() 水位等待：记 mark = rotate 前 immCount；等待 immCount < mark
  即该表已出队（其后表也一并处理完，语义更强）；等待带 30s 兜底抛错防异常悬挂；
- close：见 E。

### E. close 时序（重排，防死锁 + 保留全量落盘语义）

```
1. running=false（flusher 主循环条件）
2. writeCh.close() → flushLoop join（drain 已收请求）
3. pipeline.close()（join worker；worker 可能阻塞在 flushQueue.add —— flusher 仍在
   drain，必有空间，不死锁）
4. flushQueue.close() → flusher join（drain 剩余表：队列中表已 addTable/落盘的完成
   出队；失败放弃的表留在 imm）
5. compactor join（现状）
6. 锁内兜底 flush 剩余：allTables = mt + imm（现状 close 代码路径复用；
   flusher 失败放弃的表在此兜底落盘，失败抛错 = 现状语义）
7. 收尾（WAL/vlog/manifest 关闭，现状不变）
```

关键：**join flusher 必须先于拿写锁**（flusher 完成段需要写锁）。
flusher 在 `!running` 时不再无限重试（退出循环把表留给 close 兜底），避免 close 悬挂。

### F. TableBuilder L1（builder.cj）

- `buf: ArrayList<Byte>` → `blocks: ArrayList<Array<Byte>>` + 累计字节计数
  `writtenSize`；`finishBlock()` 压缩后整块 add（一次引用，零逐字节拷贝）；
- `finish()`：空表（keyCount==0）返回 `[]`（保留 flushToLevel 空表快路径语义，
  不再落盘空 .sst）；否则一次分配 final `Array<Byte>`（Σ块 + index + 8B 尾部），
  逐块拷贝拼接，CRC32C 增量喂入（crc-cj write 为累计状态），末尾写
  checksum(4B) + checksumSize(4B)；
- 块偏移/索引/尾部布局**位级不变** → Table/TableIndex/迭代器读路径零改动，
  现有 table 全部测试即格式回归网；
- 空表行为修正说明：旧代码 finish() 对空表也会产出非空 index 头 → 落盘空表
  （flushToLevel 的 data.size==0 分支实为死代码）；新代码显式返回空数组使该分支
  生效（空表不建表、不留空文件）。open 恢复路径与 close 的 mt.isEmpty() 判断
  本就跳过空表，行为一致性提升。

## 测试计划（TDD）

新增 `src/db/async_flusher_test.cj`（同步语义与并发回归）：

1. `testFlushMemTableSyncSemantics`：flushMemTable() 返回后数据立即可读
   （磁盘模式 + InMemory 双配置）——现有语义回归；
2. `testMultiRoundFlushDataIntegrity`：小 memTableSize + 多轮写（远超队列深度），
   全部 batchSet 成功；flushMemTable 后逐 key 验证；close→reopen 全量找回——
   背压无死锁 + 不丢数据（磁盘模式，含 io_uring 开/关）；
3. `testConcurrentReadDuringHeavyFlush`：写线程连续写触发多轮 flush，读线程
   并发 get 全部已写 key（含刚写的），断言读到值或 None 但不抛错/不悬挂；
4. `testFlushQueueDepthCapped`（包内可见性观察 immCount/imm.size 峰值）：
   NumMemtables=2 配置下峰值 ≤ 2（背压生效的直接断言——旧同步实现 imm 峰值恒 1，
   新实现必须证明背压把深度限制在配置值）；
5. `testCloseWithQueuedFlushes`：写满多轮后立即 close（不等 flushMemTable），
   close 返回后重开数据全量找回；
6. `testEmptyMemtableFlushNoFile`：flush 空 memtable 不产生 .sst（L1 行为修正）。

Builder L1 新增 `src/table/builder_l1_test.cj`（或并入现有 table 测试包）：

- 构造与旧输出**逐字节等价**无法直接对比（旧实现被替换）→ 以「Table 读回 +
  现有格式解析 + checksum 结构」为锚：多块边界 key、压缩开/关、大 value 内联
  （>64KB，32 位槽）、表索引字段一致性（keyCount/maxVersion/smallest/biggest/
  blockOffsets 与文件布局吻合）；
- TableBuilder.isEmpty()/size() 语义保持。

## 影响面与风险

| 项 | 评估 |
|---|---|
| 读路径 | 零改动（imm 遍历不变量不变；新表 addTable 后才可读） |
| 文件格式 | 零改动（L1 位级不变；异步化不动文件） |
| 失败语义 | flush 失败不再直接使写请求失败（重试+背压），比现状更接近 go；close 兜底仍抛 |
| 内存 | 峰值：memtable arena + 单张构建表（L1 后唯一一份）+ 队列深度×arena 上限（背压约束 ≤ NumMemtables×2×MemTableSize） |
| 死锁 | close/背压/水位等待三处锁序均有明确约束（等待必在写锁外） |

## 参考

- badger-go：db.go ensureRoomForWrite / handleMemTableFlush / flushMemtable /
  options.go NumMemtables（默认 5）；table/builder.go buildData
- badger-cj：#518 评审 P2-2、v1.6.12 flush 落盘语义（#520）、#524 OOM 事故链
- 本仓库先例：CloseableBlockingQueue（Mutex+Condition）、WritePipeline.loop
  Error 边界（b19a030）、vlog 两阶段 prepare/put（#519）
