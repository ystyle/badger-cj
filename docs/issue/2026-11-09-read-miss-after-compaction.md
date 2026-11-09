# 读路径：compaction 输出表上的 get 偶发 miss（数据仍在，迭代器可见）

**状态**：已知缺陷，**2.0.0 发版阻塞项**；v1.6.23（master）同样可复现 → **非 2.0 引入**。
**发现日期**：2026-11-09（2.0 阶段 7.3/发版预演期间）
**影响**：`db.get` 对部分 key 返回 None，但 `allVersions` 迭代器能看到全部条目（表 KeyCount 也完整）。

---

## 1. 确定性复现

```
Config(dir, memTableSize: 64KB, numLevelZeroTables: 1)
写 20000 个 key（键名 "ck-<i>"，值 100B，"100 个/事务"）
db.flushMemTable()
反复 db.compact() 直到只剩 1 张表      // 2.0 一次压缩即 1 张；master 需多轮
for i in 0..20000: db.get("ck-" + i)
```

实测（同机、同代码路径）：

| 版本 | 表数 | iterCount | get found | 缺失 |
|---|---|---|---|---|
| 2.0.0-dev | 1（k20000） | 20000 | 18890 | **1110** |
| v1.6.23（master） | 19（含 k10454 大表） | 20000 | 19292 | **708** |

缺失是 **get 视角**：`allVersions` 迭代器 20000/20000 可见。`[ccscan]` 诊断（并发 writer+close 用例里）也确认：miss 的 key 在迭代器里存在、版本号远小于 readTs。

## 2. 触发条件（目前观察）

- 数据集中在**一张大的 compaction 输出表**（L1）里时出现；多张小表时不易命中。
- 读取用「比任何存储版本都大的 readTs」（`db.get` 的 readTs = 最新提交 ts；重开后 = maxVersion）→ seek key 落在同 user key 组**最先**的位置。
- key 长度/块边界相关：20k 键、~600 块、约 5% 的 key 中招，不是均匀分布（成段）。

## 3. 已排除

- 不是数据丢失：表 KeyCount / 迭代器条目数完整。
- 不是 bloom filter：`TableAdapter.get` 走 TableIterator（不经 `Table.get` 的 bloom 检查）。
- 不是 lazy index 回归：2.0 与 v1.6.23 行为一致（master 也复现）。
- 不是 compaction 装表顺序：虽然本次顺带修掉了 `clearTables()+逐张 add` 的中间空档（见下），修复前后缺失量不变。

## 4. 怀疑方向（下一步）

`TableAdapter.get` → `TableIterator.seek(keyWithTs(user, readTs))` → `Table.findBlock` 的
「R3 同 user key 回退」分支：当 seek key 比存储版本更新、块首恰为**另一个 user key** 时，
`findBlock` 返回块号与 `BlockIterator.seek` 的实际落点可能不一致（`seek` 落在块内 invalid
后 TableIterator 只向**后**推进，不会回退），导致该 user key 组被跳过。

验证计划：
1. 在 table 包内构造**有序** keyWithTs 键（含多版本组跨块边界）逐 key seek，定位失败样本；
2. 打印失败 key 的 `findBlock` 块号、块首/前块首、块内 `seek` 结果；
3. 对照 go `table.Get/Seek`（go 的 block 内部有 baseKey 前缀压缩，seek 语义与我们的
   `BlockIterator.seek` 需逐条对齐）；
4. 修复后把上面 20000-key 场景固化为回归用例（当前是临时脚本，未入库）。

## 5. 顺带修复（本次已提交）

`compaction.doCompact` 原「先 `nextHandler.addTable(newTables)` 再删旧表」会在一段时间内让
**L1 同时存在重叠表**（L1+ 读路径是二分 + 不重叠假设）→ 叠加放大上面的 miss。
现在：
- `LevelHandler.replaceTables(toDelete, toAdd)`：一次锁段内重建列表 + 按 smallest 排序，
  读者只会看到旧集合或新集合；
- 装表顺序改为「manifest 先记录 → 原子替换下层 → 再摘上层 top」，与 go `runCompactDef` 一致；
- v1.6.23 的 `clearTables()+逐张 add` 中间空档（读者看到空表列表 → 直接 None）一并消除。
