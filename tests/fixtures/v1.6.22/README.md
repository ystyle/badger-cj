# v1.6.22 数据目录夹具（兼容性测试用）

**来源**：`badgercj v1.6.22`（tag `v1.6.22`，commit `48253fe`）生成的真实数据库目录，
用于验证 2.0 能打开并正确读取旧版本数据（阶段 3.2）。

**生成方式**（可复现）：
1. 在 `v1.6.22` 的独立 worktree 中加临时示例 `src/examples/fixture_gen`（内容见 git 历史），
   用 `Config(dir, memTableSize=64KB, valueThreshold=1024, syncWrites=true)` 执行：
   - 写 `small-0..9`（inline）→ `flushMemTable()`
   - 覆盖 `small-0`、写 `big-0/big-1`（2KB，进 vlog）、`ttl-key`（**TTL 10 年**）、`del-me` → `flushMemTable()`
     （TTL 必须远大于夹具寿命：夹具是长期提交的二进制，用小时级 TTL 会让 CI 在生成后一小时开始稳定失败）
   - 删除 `del-me`
   - 写 `wal-0..4`（**不 flush**）
2. 程序打印 `FIXTURE_READY` 后挂住，用 `kill -9` 终止（不执行 close）——
   因此 `3.mem` 保留未落盘数据，覆盖 2.0 的 WAL replay 路径。

**目录内容**：`MANIFEST` + 两张 `.sst` + `0.vlog`（大值）+ `3.mem`（未 flush 数据）。
**注意**：v1.6.22 不写 `FORMAT` 文件；2.0 首次打开会按「缺失 = format 1」补写。

**不要原地修改**：测试先复制到临时目录再打开。
