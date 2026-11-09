# 已废弃的实验分支（2026-10-24 归档）

两个实验分支已删除，此处保留它们的**结论与 SHA**，防止以后重复做同样的实验。
需要看原始代码时用 SHA 从 reflog 或远程取回（若已 push）。

---

## exp/single-stage-write（已删）

- **SHA**：`f17c6470a42e46029f64511e968a7ae7e4433fe9`（2026-10-06 10:43）
- **动机**：量化 WritePipeline 两级队列的开销——让 `flushLoop` 直接处理批次，
  绕过 `WritePipeline` 二级队列，省一次队列投递与一次线程唤醒。

### 为什么不采用

**它和 v1.6.22（2026-10-22）修掉的缺陷方向相反。**

实验把 `req.done()` 重新加回了 `writeRequests()` 结尾：

```cangjie
private func writeRequests(reqs: ArrayList<WriteRequest>): Unit {
    ...
    for (req in reqs) {      // ← 实验加回了这段
        req.done()
    }
}
```

同时 `writeBatchDirect()` 的 `finally` 也会 `done()` 一遍，等于**同一批请求 done 两次**。
这正是 v1.6.22 的 `12a9e09` 修掉的 bug：

> `done()` 的所有权归 `WritePipeline.runBatch()` 的 finally——本函数**不得**再 done()。
> 重复 done 会把新请求计数器 1→0 → commit 提前唤醒（返回 Ok 却读不到数据），
> 甚至请求在管道仍遍历 entries 时被 reset() 清空 →
> ConcurrentModificationException / **条目永久丢失**。

当时实验测试 375/375 能过，是因为单级路径下两遍 done 恰好没落进请求池复用的竞态窗口
（`SyncCounter.dec()` 在计数为 0 时保持不变，未复用的请求看不出问题）。
但它把「done 唯一所有权」的契约又拆成了两处——而且该分支**不含**
`write_pipeline_done_once_test.cj`（v1.6.22 加的回归守卫），等于在没有守卫的情况下重蹈覆辙。

### 另外：实验没有留下任何量化结论

提交信息只说「仅用于量化两级队列的开销」，但仓库与 cangjie-mem 里都查不到测出来的数字。
所以它连「当初想验证什么」都没沉淀下来。

### 如果以后真要重做这个优化

正确做法是在 v1.6.22 的基础上重做，且必须满足：

1. `done()` 调用点**只有一处**（不论放哪一层，所有权要唯一）；
2. 带上 `write_pipeline_done_once_test.cj` 的守卫（单线程写后立即读 + N 线程并发写后全量校验）；
3. 用两版二进制交替跑、记录端到端数字（参考下面 reusable-latch 的方法学）。

---

## feat/reusable-latch（已删）

- **SHA**：`dbc707fab0890d4bb0af0ea09f99b6817feacc49`（2026-10-06 10:16）
- **动机**：`SyncCounter` 没有 reset，每次提交都要重建对象。
  `chan-bench` 微基准显示复用信号量可把一次提交往返从 ~1150ns 降到 ~697ns（**-39%**）。

### 实测结论：端到端无收益，不合并

`txn_queue_perf`，两版二进制交替 18 轮：

| 指标 | 结果 |
|---|---|
| 均值 | 4639.6 vs 4669.7 ns/txn（**-0.6%**） |
| 中位数 | -0.5% |
| 逐轮配对 | 10/18（接近抛硬币） |
| Welch t | **-0.26** |
| 方差 | 不降反升（σ 412 vs 267） |

微基准的 -39% 收益在真实写路径上被其它开销完全稀释。

### 为什么不值得冒险

除了「没收益」，它还引入两个隐式约束：

- **Semaphore 许可钳制**——许可数设错就会静默阻塞；
- **必须严格一对一配对**——多一次或少一次 `release` 会造成许可泄漏或提前唤醒，
  这类错误在压测里很难稳定复现。

用「-0.6% 的噪音级收益」换这两个约束不划算。

### 方法学值得复用

这个实验的验证方式本身是对的，以后做性能类实验照此办理：

- 两版二进制**交替**跑（同一时间窗控负载漂移），不是各跑一遍；
- 看**逐轮配对数 + 中位数**，不只看均值（均值易被离群值带偏）；
- 报 **Welch t** 与**方差**——方差变大说明稳定性更差，即使均值略好也不该采纳；
- 明确「微基准收益 ≠ 端到端收益」，后者才是决策依据。

---

## 相关工作

- 写管道 done 契约与 v1.6.22 修复细节：cangjie-mem `library` 级
  「写管道重复 done()」（badgercj）
- 存活性边界（`catch(Error)` 三件套：WritePipeline.loop / flusherLoop / compactor）：
  cangjie-mem「服务边界 Error 防护」
