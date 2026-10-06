package badgercj.db

import std.sync.*

/**
 * CloseableBlockingQueue — Go 有缓冲 channel 的仓颉实现（单锁环形缓冲）
 *
 * 行为与 Go 的 `make(chan T, capacity)` 一致：
 * - add(item): 满时阻塞，close 后抛异常 (send on closed channel)
 * - remove():  空时阻塞，close 且排空后返回 None
 * - tryRemove(): 非阻塞取，无数据时返回 None
 * - close(): 关闭队列，唤醒所有等待的生产者与消费者
 *
 * 实现要点（相对"阻塞队列 + 外挂锁通知"的写法）：
 * - 定长环形数组承载数据，入队/出队/判空/判满在同一次临界区内完成，不存在第二把锁；
 * - 条件通知按需下发：仅当确实存在等待者时才进入条件变量，避免每次操作都空唤一次；
 * - 等待计数在进锁前递增、进锁后复查队列状态，故不会丢唤醒；
 * - 队满等待会同时观察 closed，close 后阻塞中的生产者立即失败而不是等到被消费唤醒。
 */
protected class CloseableBlockingQueue<T> {
    private let buf: Array<?T>
    private let capacity: Int64
    private var head: Int64 = 0
    private var tail: Int64 = 0
    private var count: Int64 = 0
    private var closed = false
    private let lock = Mutex()
    private let notEmpty: Condition
    private let notFull: Condition
    private let waitingConsumers = AtomicInt64(0)
    private let waitingProducers = AtomicInt64(0)

    public init(capacity: Int64) {
        if (capacity <= 0) {
            throw Exception("CloseableBlockingQueue 容量必须为正数：${capacity}")
        }
        this.buf = Array<?T>(capacity, repeat: Option<T>.None)
        this.capacity = capacity
        synchronized(lock) {
            notEmpty = lock.condition()
            notFull = lock.condition()
        }
    }

    public func add(item: T): Unit {
        synchronized(lock) {
            while (count == capacity && !closed) {
                waitingProducers.fetchAdd(1)
                notFull.wait()
                waitingProducers.fetchSub(1)
            }
            if (closed) {
                throw Exception("send on closed channel")
            }
            buf[tail] = Some(item)
            tail = if (tail + 1 == capacity) { 0 } else { tail + 1 }
            count++
            if (waitingConsumers.load() > 0) {
                notEmpty.notify()
            }
        }
    }

    public func remove(): ?T {
        var result: ?T = Option<T>.None
        synchronized(lock) {
            while (count == 0 && !closed) {
                waitingConsumers.fetchAdd(1)
                notEmpty.wait()
                waitingConsumers.fetchSub(1)
            }
            if (count > 0) {
                result = buf[head]
                buf[head] = Option<T>.None
                head = if (head + 1 == capacity) { 0 } else { head + 1 }
                count--
                if (waitingProducers.load() > 0) {
                    notFull.notify()
                }
            }
        }
        result
    }

    public func tryRemove(): ?T {
        var result: ?T = Option<T>.None
        synchronized(lock) {
            if (count > 0) {
                result = buf[head]
                buf[head] = Option<T>.None
                head = if (head + 1 == capacity) { 0 } else { head + 1 }
                count--
                if (waitingProducers.load() > 0) {
                    notFull.notify()
                }
            }
        }
        result
    }

    public func size(): Int64 {
        synchronized(lock) {
            count
        }
    }

    public func close(): Unit {
        synchronized(lock) {
            if (closed) {
                return
            }
            closed = true
            notEmpty.notifyAll()
            notFull.notifyAll()
        }
    }

    public func isClosed(): Bool {
        synchronized(lock) {
            closed
        }
    }
}
