# Issue: 正常运行期间 memtable flush 不落盘 → 内存无限增长 OOM → MCP 挂起（写路径腐化）

- **报告日期**: 2026-09-02
- **涉及模块**: badger-cj（write/flush 路径）+ 下游 chronomem（jsonrpc 协程健壮性）
- **严重性**: 高（生产服务"连不上"，写路径全部失败）
- **状态**: 待修复

---

## 1. 问题概述

在生产容器（docker 默认 seccomp，**io_uring 被禁**）中长期运行时，memtable 写满后 **flush 只建内存表、不落盘**（`flushToLevel` 无任何写盘调用），数据全部堆积在内存 L0 表。长时间运行 → 内存持续增长 → **GC 堆 OOM（`OutOfMemoryError`）**。

OOM 是仓颉 `Error`（非 `Exception`），下游 jsonrpc 的 `receiveLoop` 只 `catch (e: Exception)`，**Error 逃逸杀死 MCP 处理协程** → 消息队列无人消费 → 所有后续请求 30s 超时 → 客户端表现为 **"服务连不上 / 全部写失败"**。

写入"成功"但数据不落盘的另一层原因：`flushMemTableToDisk`/`flushMemTablesBatch` **忽略写盘返回值**，io_uring 被禁走降级同步写时若写失败，数据静默丢失。

## 2. 环境

| 项 | 值 |
|---|---|
| 容器 | docker 默认 seccomp（**非 privileged**） |
| io_uring | **被禁**（`io_uring_setup` 返回 `errno=1 EPERM`）；宿主可用 |
| 二进制 | badger-cj 1.6.9/1.6.10 + chronomem fix/gc-heap-oom |
| 内存 | 仓颉 GC 堆默认上限 256MB |

> ⚠️ **复现环境关键**：必须用**默认 seccomp 容器**（io_uring 被禁，走降级同步写路径）。
> 用 `--privileged` 容器（io_uring 可用）复现**不会**得到生产现象——两者代码路径不同。
> 宿主直测 io_uring：`io_uring_setup` OK（fd=3）；容器内：`errno=1 Operation not permitted`。

## 3. 复现步骤（全部用自造数据，不碰生产数据）

### 3.1 环境准备

```bash
# 编译旧代码调试版（或任意版本二进制，现象与版本无关）
# 构建 chronomem 调试版容器（非 privileged！）

docker run -d --name exp-flush --restart no \
  -v <chronomem.cli>:/app/chronomem.cli \
  -v <空数据目录>:/home/app/.chronolog \
  -p 8931:8900 \
  -e CHRONOLOG_DIR=/home/app/.chronolog \
  -e CHRONOLOG_ADDR=0.0.0.0 -e CHRONOLOG_PORT=8900 \
  -e CHRONOLOG_UI_ENABLED=false \
  chronomem:latest

# 验证 io_uring 被禁（关键前置条件）
docker cp <uring_test> exp-flush:/t && docker exec exp-flush /t
# 期望输出: io_uring_setup FAILED: errno=1 (Operation not permitted)
```

### 3.2 触发

向 `mem/append`（worklog 类型）连续写入**合法大小** payload（< 64KB，如 40KB），总量超过 memtable 16MB：

```python
# 400 × 40KB = 16MB，写满 memtable
for i in range(400):
    payload = {"task": f"p{i}", "status": "x", "outcome": "P" * 40000}
    call("mem/append", {"type": "worklog", "payload": payload})
```

### 3.3 观察

写入全部返回成功（`isError=false`），但：

- **数据文件**：`0.mem`（WAL）停在 ~16MB，**无任何 `.sst` 文件**，`MANIFEST` 0 字节
  ```
  -rw-r--r-- 16108988 0.mem
  -rw-r--r--        0 0.vlog
  -rw-r--r--        0 MANIFEST
  ```
- **内存**：持续增长至 `OutOfMemoryError`（日志出现）
- **MCP**：后续请求全部超时挂起（HTTP 无响应；线程全部 park 在 `CJ_CJThreadMpark`，无死锁、无忙等——即处理协程已死）
- **对照**：`docker stop` 优雅关闭后，close 路径才写出 `000000.sst`（16MB）+ MANIFEST——**证明数据只在 close 时才落盘**

## 4. 根因分析

### 4.1 正常运行无落盘（主因）

`badger.cj:584-617`：

```
flushMemTableInternal():
    imm.add(mt)
    mt = MemTable(opt, fid, false)   // 新 memtable
    flushToLevel(imm[last])

flushToLevel(mt):
    builder...finish() → data
    table = Table(tableID, data)
    lc.addTable(0, TableAdapter(table))   // ← 只建【内存表】，无写盘！
    mt.decrRef()
```

- memtable 满 16MB → `flushToLevel` 把数据做成**内存表**塞进 L0，**不调用任何写盘函数**
- 写盘仅发生在：① `close()`（`flushMemTableToDisk`/`flushMemTablesBatch`）② compaction（L0 表数 > `NumLevelZeroTables`(默认4) 才触发）
- 结果：低频写入（本场景 16MB 只产生 1 个内存表，< 4 不触发 compaction）→ 数据只堆内存 → 长时间运行必然 OOM

### 4.2 写盘结果被忽略（加剧数据丢失）

- `badger.cj:362` `flushMemTablesBatch`：`writeFilesBatch(requests, useIoUring: true)` **返回值（FileWriteResult 列表）完全未检查**——io_uring/降级写失败会静默丢数据
- `badger.cj:401` `flushMemTableToDisk`：`writeFile(path, data, useIoUring: ...)` **返回值（写入字节数）完全未检查**
- io_uring 被禁时 `createIoUringWriter` 返回 None → 走同步 `File.write`；若此处失败，调用方无感知

### 4.3 OOM 杀死 MCP 协程（"连不上"的直接表现）

`json-rpc/jsonrpc/src/server.cj:216-235`：

```
receiveLoop():
    while (isRunning()):
        match (transport.receive()):
            case Some(data) =>
                while (let Some((body, consumed)) <- framing.decode(...)):
                    try { this.handleMessage(body) }
                    catch (e: Exception) { println(...) }   // ← 只 catch Exception！
```

- tool handler 抛 `OutOfMemoryError`（Error 类）→ `handleCallTool` 只 catch Exception → 逃逸 `handleMessage` → 逃逸 `receiveLoop` → **协程死亡**
- 线程栈现象：所有 schd-worker park 在 `CJ_CJThreadMpark`（无锁等待、无忙等），epoll 仍在等——就是没有协程消费消息队列了
- 之后每个请求进 `messageQueue` 等 30s（`respCond.wait(timeout: 30s)`）→ 客户端先超时 → 表现为挂起

## 5. 相关代码位置

| 位置 | 问题 |
|---|---|
| `badger-cj/src/db/badger.cj:584-617` | `flushToLevel` 只建内存表不落盘（**主因**） |
| `badger-cj/src/db/badger.cj:362` | `writeFilesBatch` 返回值未检查 |
| `badger-cj/src/db/badger.cj:401` | `writeFile` 返回值未检查 |
| `badger-cj/src/db/badger.cj:336-377` | `flushMemTablesBatch` 忽略 `FileWriteResult` |
| `badger-cj/src/db/compaction.cj:232-330` | compaction 写盘路径（唯一正常运行时的落盘点，依赖 L0 表数阈值） |
| `json-rpc/jsonrpc/src/server.cj:216-235` | `receiveLoop` 只 catch Exception，Error 逃逸杀协程 |
| `mcp-cj/src/transport/v2025_11_25_streamable_server.cj:122-152` | `handlePost` 等 `respCond` 30s，无人响应则超时 |

## 6. 复现产物（本次实测数据，供修复验证）

- 非 privileged 容器 + 旧调试版二进制：写 400×40KB，全成功；WAL 16MB、无 sst、无 MANIFEST；日志 `OutOfMemoryError`；MCP 挂起（HTTP 000）
- 同容器 `docker stop` 后：`000000.sst`(16MB) + MANIFEST(12B) 生成——close 落盘正常，证明降级同步写本身可用
- 对照组：`--privileged` 容器（io_uring 可用）同样操作**不**复现（实验环境 ≠ 生产环境，务必注意）

## 7. 建议修复方向（供参考）

1. **主修复**：正常运行时应把 memtable flush 成 **SSTable 落盘**（对齐 badger-go：`flushMemTableInternal` 应写盘 + MANIFEST，而非只建内存表），或至少保证 L0 内存表会及时被 compaction 落盘（检查阈值/触发条件为何没生效）
2. **防御**：`flushMemTablesBatch`/`flushMemTableToDisk` 检查写盘结果（`FileWriteResult.ok`/写入字节数），失败必须抛异常或 markFailed，禁止静默
3. **协程健壮性**：jsonrpc `receiveLoop` 与 `handleCallTool` 等 handler 边界增加对 `Error` 的兜底（记录 + 继续服务，或至少不让单条消息杀死整个循环）——按仓颉规范 Error 不捕获，但服务循环被杀等同于永久停机，需权衡（或由调用方 prevent OOM）
4. **环境一致性**：所有容器实验必须用默认 seccomp（io_uring 被禁），privileged 容器结果不代表生产

## 8. 备注

- 本 issue 基于自造数据复现（未使用生产数据）
- 生产现象与此完全吻合：materialize 每分钟写 bucket 失败 584 次、`2.mem`(WAL) 卡在 14.5MB 不落盘、SSTable 永不更新、最终写路径全挂
