package badgercj.db

import std.sync.*
import std.collection.concurrent.*

/**
 * CloseableBlockingQueue — Go 有缓冲 channel 的仓颉实现
 *
 * 行为与 Go 的 `make(chan T, capacity)` 一致：
 * - add(item): 满时阻塞，close 后抛异常 (send on closed channel)
 * - remove():  空时阻塞，close 后返回 None
 * - tryRemove(): 非阻塞取，无数据时返回 None
 * - close(): 关闭 channel，唤醒所有等待的消费者
 *
 * 内部使用 LinkedBlockingQueue 做 O(1) 存储，Mutex + Condition 实现 close 唤醒。
 */
protected class CloseableBlockingQueue<T> {
    private let queue: LinkedBlockingQueue<T>
    private let lock = Mutex()
    private let cond: Condition
    private let closed = AtomicBool(false)

    public init(capacity: Int64) {
        this.queue = LinkedBlockingQueue<T>(capacity)
        synchronized(lock) {
            this.cond = lock.condition()
        }
    }

    public func add(item: T): Unit {
        if (closed.load()) {
            throw Exception("send on closed channel")
        }
        queue.add(item)
        synchronized(lock) {
            cond.notify()
        }
    }

    public func remove(): ?T {
        var result: ?T = None
        while (true) {
            if (let Some(item) <- queue.tryRemove()) {
                result = Some(item)
                break
            }
            if (closed.load()) {
                break
            }
            synchronized(lock) {
                while (queue.size == 0 && !closed.load()) {
                    cond.wait()
                }
            }
            if (closed.load() && queue.size == 0) {
                break
            }
        }
        result
    }

    public func tryRemove(): ?T {
        queue.tryRemove()
    }

    public func size(): Int64 {
        queue.size
    }

    public func close(): Unit {
        if (closed.swap(true)) {
            return
        }
        synchronized(lock) {
            cond.notifyAll()
        }
    }

    public func isClosed(): Bool {
        closed.load()
    }
}
