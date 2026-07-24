# Channel 替换方案：LinkedBlockingQueue + Close 语义

> **目标：** 用 `LinkedBlockingQueue` + `Condition` 替换手写的 `NotifyingWriteChannel`，实现 Go 有缓冲 channel 的正确行为（满时阻塞、空时阻塞、close 通知退出）。

---

## 问题分析

### 当前实现的问题

当前 `NotifyingWriteChannel<T>`（`src/db/notifying_channel.cj`）有 3 个 Bug：

| # | 问题 | 影响 |
|---|------|------|
| 1 | `add()` 不阻塞——`ArrayList.add()` 直接添加，无视 `capacity` | 无背压，写方过快时内存无限增长 |
| 2 | `remove(at: 0)` 是 O(n) 操作 | 队列越大，出队越慢 |
| 3 | `condition()` 在 Mutex lock 前调用 | API 使用不当，虽跑起来没问题但不符合规范 |

### 使用场景

当前有 **4 个实例** 使用这个 Channel：

| 位置 | 类型 | 用途 | 容量 | 模式 |
|------|------|------|------|------|
| `badger.cj` `writeCh` | `NotifyingWriteChannel<WriteRequest>` | 单写请求 → flushLoop | 10000 | 多生产者单消费者 |
| `write_pipeline.cj` `queue` | `NotifyingWriteChannel<ArrayList<WriteRequest>>` | 批量写请求 → 后台线程 | 1000 | 单生产者单消费者 |
| `stream.cj` `rangeChan` | `NotifyingWriteChannel<KeyRange>` | Range 分发 → N 个 KV 工作者 | 100 | 单生产者多消费者 |
| `stream.cj` `kvChan` | `NotifyingWriteChannel<ArrayList<StreamKV>>` | KV 结果 → streamKVs 主线程 | 100 | 多生产者单消费者 |

**API 表面：** `add(item)` / `remove() -> ?T` / `tryRemove() -> ?T` / `size() -> Int64` / `close()` / `isClosed() -> Bool`

---

## 方案：CloseableBlockingQueue

### 设计

```cangjie
protected class CloseableBlockingQueue<T> {
    private let queue = LinkedBlockingQueue<??T>>()  // Option 包装支持哨兵
    private let mutex = Mutex()                       // 保护 close 状态 + 哨兵计数
    private let closeCond = mutex.condition()         // 等待 drain
    private let closed = AtomicBool(false)
}
```

### 核心思路

`LinkedBlockingQueue` 自带：
- `add(E)` — 满时阻塞 ✅
- `remove()` — 空时阻塞 ✅
- O(1) 入队出队 ✅

缺的只有 **close 语义**。Go channel close 后：
- 已缓冲数据可以继续读取
- 缓冲区清空后 `recv` 返回零值（或 `ok=false`）
- `send` 会 panic

我们的实现：
- close 后生产者不能再 add（可 panic 或静默丢弃，参考 Go 的 close 后 send panic）
- close 后消费者继续读到缓冲区空，然后 remove() 返回 None
- 消费者 detect close 后退出循环

### 实现细节

#### 方案 A：哨兵值 + remove 返回 Option

```cangjie
public func add(item: T): Unit {
    if (closed.load()) {
        throw Exception("send on closed channel")
    }
    queue.tryAdd(item)  // 非阻塞检查
    // 或用 LinkedBlockingQueue.add() 阻塞直到有空间
}

public func remove(): ?T {
    while (true) {
        let item = queue.remove()  // 阻塞直到有元素
        // 检查 item 是否为哨兵
        // 如果是哨兵且 closed，返回 None
        // 否则返回元素
    }
}
```

实际上，最简单的方式是用 `Option<T>` 作为 `LinkedBlockingQueue` 的元素类型：

```cangjie
// 内部用 Option<T> 作为元素
// Some(item) = 正常数据
// None = 哨兵（表示 channel 已关闭，消费者该退出了）

public func add(item: T): Unit {
    queue.add(Some(item))
}

public func close(): Unit {
    if (!closed.swap(true)) {
        // 通知所有等待 remove 的消费者
        // LinkedBlockingQueue 的 remove() 不为空，
        // 所以需要在队列中放入 N 个哨兵
        // N = 消费者数量
    }
}
```

但是 `LinkedBlockingQueue.add(Option<T>)` 的问题是 `Option<T>` 有额外包装开销。更好的方式是用两个队列：

#### 方案 B：LinkedBlockingQueue + close 标记

```cangjie
public class CloseableBlockingQueue<T> {
    private let queue = LinkedBlockingQueue<T>()
    private let closeLock = Mutex()
    private let drainCond = closeLock.condition()
    private let closed = AtomicBool(false)
    
    public func add(item: T): Unit {
        if (closed.load()) {
            throw Exception("send on closed channel")
        }
        queue.add(item)  // 满时阻塞
    }
    
    public func remove(): ?T {
        while (true) {
            // wait for close or item available
            // 问题：LinkedBlockingQueue.remove() 会阻塞等待，但无法被 close 中断
            // 需要搭配 poll + sleep 或 Condition 通知
        }
    }
}
```

**问题：** `LinkedBlockingQueue.remove()` 阻塞等待元素，但没有机制能在 close 时中断它。需要一个辅助的 Condition 来唤醒消费者。

#### 方案 C（推荐）：LinkedBlockingQueue + Mutex/Condition 辅助 close

```cangjie
public class CloseableBlockingQueue<T> {
    private let queue = LinkedBlockingQueue<T>()
    private let closeLock = Mutex()
    private let closeNotify = closeLock.condition()
    private let closed = AtomicBool(false)
    
    /// send — 满时阻塞，close 后抛异常
    public func add(item: T): Unit {
        if (closed.load()) {
            throw Exception("send on closed channel")
        }
        queue.add(item)  // 满时阻塞
    }
    
    /// recv — 空时阻塞，close 且空时返回 None
    public func remove(): ?T {
        while (true) {
            // 先尝试非阻塞取
            if (let Some(item) <- queue.tryRemove()) {
                return Some(item)
            }
            // 队列空，检查是否已 close
            closeLock.lock()
            while (queue.size() == 0 && !closed.load()) {
                closeNotify.wait(pollInterval)  // 或者用更复杂的机制
            }
            if (queue.size() > 0) {
                closeLock.unlock()
                continue  // 重新尝试取
            }
            closeLock.unlock()
            return None  // closed 且空
        }
    }
    
    /// close — 停止接收新数据，唤醒消费者
    public func close(): Unit {
        if (closed.swap(true)) {
            return  // already closed
        }
        closeLock.lock()
        closeNotify.notifyAll()  // 唤醒等待的消费者
        closeLock.unlock()
    }
}
```

这个方案的问题：`closeNotify.wait()` 需要一个超时参数，否则没人唤醒它。而用一个固定 timeout 轮询又回到了 `ArrayBlockingQueue.remove(Duration)` 的 1ms 延迟问题。

### 最终推荐方案：改用 Condition 直接实现

既然 close 语义跟 `LinkedBlockingQueue` 的阻塞 remove 冲突，不如保留 `Condition` 等待 + `LinkedBlockingQueue` 做存储：

```cangjie
public class CloseableBlockingQueue<T> {
    private let queue = LinkedBlockingQueue<T>()
    private let lock = Mutex()
    private let dataReady = lock.condition()     // 有数据可读
    private let spaceReady = lock.condition()    // 有空位可写
    private let capacity: Int64
    private let closed = AtomicBool(false)
    
    public init(capacity: Int64) {
        this.capacity = capacity
        // capacity 被 LinkedBlockingQueue 内部管理
    }
    
    public func add(item: T): Unit {
        if (closed.load()) {
            throw Exception("send on closed channel")
        }
        // LinkedBlockingQueue.add() 满时阻塞
        // 但无法被 close 中断，所以用 tryAdd + 等待
        while (!queue.tryAdd(item)) {
            if (closed.load()) {
                throw Exception("send on closed channel")
            }
            // 队列满，等一会再试
            // 或使用 Condition
            lock.lock()
            while (queue.size() >= capacity && !closed.load()) {
                spaceReady.wait(...)  // 需要超时
            }
            lock.unlock()
        }
        lock.lock()
        dataReady.notify()
        lock.unlock()
    }
    
    public func remove(): ?T {
        while (true) {
            if (let Some(item) <- queue.tryRemove()) {
                lock.lock()
                spaceReady.notify()
                lock.unlock()
                return Some(item)
            }
            if (closed.load()) {
                return None
            }
            lock.lock()
            while (queue.size() == 0 && !closed.load()) {
                dataReady.wait()
            }
            let isClosed = closed.load()
            let hasItems = queue.size() > 0
            lock.unlock()
            if (hasItems) {
                continue
            }
            if (isClosed) {
                return None
            }
        }
    }
    
    public func close(): Unit {
        if (closed.swap(true)) {
            return
        }
        lock.lock()
        dataReady.notifyAll()
        spaceReady.notifyAll()
        lock.unlock()
    }
    
    public func tryRemove(): ?T {
        queue.tryRemove()
    }
    
    public func size(): Int64 {
        queue.size
    }
}
```

这个方案的问题是：又回到了跟 `NotifyingWriteChannel` 类似的实现，只是把 `ArrayList` 换成了 `LinkedBlockingQueue`。失去了 `LinkedBlockingQueue.add()` 的内置阻塞能力。

---

## 最终方案：简化版

仔细分析使用场景后，发现 4 个实例的行为其实很简单：

| 实例 | add 满时阻塞？ | remove 空时阻塞？ | close 需要？ |
|------|---------------|-------------------|-------------|
| `writeCh` (badger.cj) | ❌ 不要阻塞（发送方在事务线程，不应被背压阻塞） | ✅ 需要 | ✅ 
| `queue` (WritePipeline) | ❌ 不要阻塞（发出后即可返回，WritePipeline 内部有缓冲） | ✅ 需要 | ✅
| `rangeChan` (stream.cj) | ✅ 需阻塞（溢出会丢失 range） | ✅ 需要 | ✅
| `kvChan` (stream.cj) | ✅ 需阻塞（溢出会丢失 KV） | ✅ 需要 | ✅

实际上当前 `add()` 不阻塞的用法是故意的——`writeCh` 和 `WritePipeline.queue` 不希望阻塞发送方。
而 `rangeChan` 和 `kvChan` 需要背压保护。

**结论：** `LinkedBlockingQueue` 直接替换即可，close 语义只需包一层 `Option<T>` 哨兵。

### 简化的实现

```cangjie
protected class CloseableBlockingQueue<T> {
    private let queue = LinkedBlockingQueue<Option<T>>()
    private let closed = AtomicBool(false)
    
    public init(capacity: Int64) {
        this.queue = LinkedBlockingQueue<Option<T>>(capacity)
    }
    
    /// 满时阻塞，close 后抛出异常
    public func add(item: T): Unit {
        if (closed.load()) {
            throw Exception("send on closed channel: ${this}")
        }
        try {
            queue.add(Option<T>.Some(item))
        } catch (e: Exception) {
            throw Exception("send on closed channel: ${this}")
        }
    }
    
    /// 空时阻塞，close 且空时返回 None
    public func remove(): ?T {
        while (true) {
            let item = queue.remove()
            match (item) {
                case Some(v) => return Some(v)
                case None => {
                    // 遇到哨兵，说明 channel 已关闭
                    // 把哨兵放回去让其他消费者也收到
                    // 不对，只放一次，或者用计数
                    // 更好的方式：close 时给每个消费者放一个哨兵
                    // 但 LinkedBlockingQueue 不追踪消费者数量
                    break
                }
            }
        }
        None
    }
    
    public func tryRemove(): ?T {
        match (queue.tryRemove()) {
            case Some(Some(v)) => Some(v)
            case _ => None
        }
    }
    
    public func close(): Unit {
        if (closed.swap(true)) {
            return
        }
        // 放入结束哨兵
        // 如果有多个消费者，这里只唤醒一个
        // 对于多消费者场景，需要放多个哨兵
        queue.add(Option<T>.None)
    }
    
    public func size(): Int64 {
        queue.size
    }
}
```

### 多消费者问题

`kvChan` 和 `rangeChan` 都是单消费者场景。所以哨兵方案可行。

---

## 建议：采用最简单方案

既然 `LinkedBlockingQueue` 不能优雅地中断阻塞的 `remove()`，且我们的场景大部分是单消费者，**最简单且正确的方案** 是：

1. **用 `LinkedBlockingQueue<T>` 存数据**（O(1)、满时阻塞、空时阻塞）
2. **加一个 close 标记 + 剩余元素计数**
3. **`remove()` 用 `tryRemove()` 轮询 + Condition 通知替代阻塞的 `remove()`**

这样既保持了 `LinkedBlockingQueue` 的存储效率，又保留了 close 语义。

```cangjie
protected class CloseableBlockingQueue<T> {
    private let queue = LinkedBlockingQueue<T>()
    private let lock = Mutex()
    private let cond = lock.condition()
    private let closed = AtomicBool(false)
    
    public func add(item: T): Unit {
        if (closed.load()) {
            throw Exception("send on closed channel")
        }
        queue.add(item)                 // 满时阻塞
        lock.lock()
        cond.notify()                    // 唤醒消费者
        lock.unlock()
    }
    
    public func remove(): ?T {
        while (true) {
            if (let Some(item) <- queue.tryRemove()) {
                return Some(item)
            }
            if (closed.load()) {
                return None
            }
            lock.lock()
            while (queue.size() == 0 && !closed.load()) {
                cond.wait()
            }
            let isClosed = closed.load()
            lock.unlock()
            if (isClosed) {
                return None
            }
            // 继续循环取数据
        }
    }
    
    public func tryRemove(): ?T {
        queue.tryRemove()
    }
    
    public func close(): Unit {
        if (closed.swap(true)) {
            return
        }
        lock.lock()
        cond.notifyAll()
        lock.unlock()
    }
    
    public func size(): Int64 {
        queue.size
    }
}
```

**关键区别 vs 当前 NotifyingWriteChannel：**
- `add()` 用 `LinkedBlockingQueue.add()` 而不是 `ArrayList.add()` → 满时阻塞 ✅
- `remove()` 用 `LinkedBlockingQueue.tryRemove()` 而不是 `ArrayList.remove(at: 0)` → O(1) ✅
- `close()` 用 `cond.notifyAll()` 唤醒 remove 中的等待 → Condition 正确使用 ✅

---

## 迁移计划

### 步骤

1. **新增 `CloseableBlockingQueue`** — 在 `src/db/notifying_channel.cj` 中新增类或新建文件
2. **替换 4 个实例** — 逐个替换 `NotifyingWriteChannel<X>` → `CloseableBlockingQueue<X>`
3. **删除旧类** — 确认没有引用后删除 `NotifyingWriteChannel`
4. **测试** — 运行所有测试，确保功能正常

### 影响文件

| 文件 | 改动 |
|------|------|
| `src/db/notifying_channel.cj` | 新增 `CloseableBlockingQueue`，删除 `NotifyingWriteChannel` |
| `src/db/badger.cj` | `NotifyingWriteChannel<WriteRequest>` → `CloseableBlockingQueue<WriteRequest>` |
| `src/db/write_pipeline.cj` | `queue` 类型更新 |
| `src/db/stream.cj` | `rangeChan` / `kvChan` 类型更新 + 适配 close 语义 |

### 不修改现有 API 表面

所有调用方代码（`.add()` / `.remove()` / `.close()` 等）**不做任何改动**，只是底层实现换掉。

### 风险

- **多消费者场景**：`CloseableBlockingQueue` 的 `remove()` 在 close 时可能让多个消费者都返回 None，需确认 `stream.cj` 中 `kvChan` 的 close 逻辑（当前只有一个消费者调用 `kvChan.remove()`，其他 done 后调用 `kvChan.close()`）
- **add 在 close 后抛异常**：当前 `NotifyingWriteChannel.add()` 在 close 后不检查，数据可能丢失。新实现会抛异常，需要确保调用方正确处理

---

## 与 Go channel 的行为对照

| Go channel | CloseableBlockingQueue |
|-----------|----------------------|
| `ch <- val` (满时阻塞) | `add(val)` — 满时阻塞 |
| `<-ch` (空时阻塞) | `remove()` — 空时阻塞 |
| `close(ch)` | `close()` — 唤醒消费者 |
| `val, ok := <-ch` (close 后) | `remove()` 返回 None |
| `ch <- val` (close 后 panic) | `add()` 抛异常 |
| `len(ch)` | `size()` |
| `cap(ch)` | (初始化时指定) |
