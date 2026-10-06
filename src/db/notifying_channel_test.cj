package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.sync.*
import std.collection.*

/**
 * CloseableBlockingQueue 的语义契约测试。
 *
 * 覆盖：FIFO 与环形回绕、满/空阻塞、close 唤醒全部等待者、close 后排空、
 * close 后 add 失败、tryRemove 非阻塞、size 精确、MPMC 不重不漏。
 */
@Test
class CloseableBlockingQueueTest {
    @TestCase
    func testFifoOrderWithWraparound() {
        // 容量 3 而推送 200 条：head/tail 必然多次回绕
        let q = CloseableBlockingQueue<Int64>(3)
        var ok = true
        for (i in 0..200) {
            q.add(i)
            match (q.remove()) {
                case Some(v) =>
                    if (v != i) {
                        ok = false
                    }
                case None => ok = false
            }
        }
        @Expect(ok)
        @Expect(q.size(), 0)
    }

    @TestCase
    func testConcurrentProducerConsumerPreservesOrder() {
        let q = CloseableBlockingQueue<Int64>(3)
        let n: Int64 = 2000
        let producer = spawn {
            for (i in 0..n) {
                q.add(i)
            }
            q.close()
        }
        var next: Int64 = 0
        var ok = true
        while (true) {
            match (q.remove()) {
                case Some(v) =>
                    if (v != next) {
                        ok = false
                    }
                    next++
                case None => break
            }
        }
        producer.get()
        @Expect(ok)
        @Expect(next, n)
    }

    @TestCase
    func testRemoveBlocksUntilDataArrives() {
        let q = CloseableBlockingQueue<Int64>(4)
        let consumer = spawn {
            q.remove()
        }
        sleep(Duration.millisecond * 20)
        q.add(42)
        @Expect(consumer.get(), Some(42))
    }

    @TestCase
    func testFullQueueBlocksProducer() {
        let q = CloseableBlockingQueue<Int64>(2)
        q.add(1)
        q.add(2)
        let producer = spawn {
            q.add(3)
            true
        }
        sleep(Duration.millisecond * 50)
        // 生产者应仍被容量挡住：条目数不会超过容量
        @Expect(q.size(), 2)
        @Expect(q.remove(), Some(1))
        @Expect(producer.get())
        @Expect(q.size(), 2)
        @Expect(q.remove(), Some(2))
        @Expect(q.remove(), Some(3))
    }

    @TestCase
    func testCloseWakesAllBlockedConsumers() {
        let q = CloseableBlockingQueue<Int64>(4)
        let consumers = ArrayList<Future<?Int64>>()
        for (_ in 0..4) {
            consumers.add(spawn {
                q.remove()
            })
        }
        sleep(Duration.millisecond * 20)
        q.close()
        for (f in consumers) {
            @Expect(f.get().isNone())
        }
    }

    @TestCase
    func testDrainRemainingAfterClose() {
        let q = CloseableBlockingQueue<Int64>(8)
        for (i in 0..5) {
            q.add(i)
        }
        q.close()
        var got: Int64 = 0
        while (true) {
            match (q.remove()) {
                case Some(_) => got++
                case None => break
            }
        }
        @Expect(got, 5)
    }

    @TestCase
    func testAddAfterCloseThrowsAndCloseIsIdempotent() {
        let q = CloseableBlockingQueue<Int64>(2)
        q.close()
        q.close()
        @Expect(q.isClosed())
        var threw = false
        try {
            q.add(1)
        } catch (e: Exception) {
            threw = true
        }
        @Expect(threw)
    }

    @TestCase
    func testBlockedProducerFailsOnClose() {
        // 队满时 close：阻塞中的生产者必须失败返回，而不是等到被消费唤醒
        let q = CloseableBlockingQueue<Int64>(1)
        q.add(1)
        let producer = spawn {
            var threw = false
            try {
                q.add(2)
            } catch (e: Exception) {
                threw = true
            }
            threw
        }
        sleep(Duration.millisecond * 20)
        q.close()
        @Expect(producer.get())
    }

    @TestCase
    func testTryRemoveIsNonBlocking() {
        let q = CloseableBlockingQueue<Int64>(2)
        @Expect(q.tryRemove().isNone())
        q.add(7)
        @Expect(q.tryRemove(), Some(7))
        @Expect(q.size(), 0)
        @Expect(q.tryRemove().isNone())
    }

    @TestCase
    func testSizeTracksInFlightItems() {
        let q = CloseableBlockingQueue<Int64>(8)
        @Expect(q.size(), 0)
        for (i in 0..5) {
            q.add(i)
            @Expect(q.size(), i + 1)
        }
        for (i in 0..5) {
            q.remove()
            @Expect(q.size(), 4 - i)
        }
    }

    @TestCase
    func testMpmcDeliversEveryItemExactlyOnce() {
        let producers: Int64 = 4
        let consumers: Int64 = 4
        let per: Int64 = 500
        let q = CloseableBlockingQueue<Int64>(8)
        let done = AtomicInt64(0)
        let producerFutures = ArrayList<Future<Unit>>()
        for (pid in 0..producers) {
            let base = pid * per
            producerFutures.add(spawn {
                for (i in 0..per) {
                    q.add(base + i)
                }
                if (done.fetchAdd(1) + 1 == producers) {
                    q.close()
                }
            })
        }
        let seen = ArrayList<AtomicInt64>()
        for (_ in 0..producers * per) {
            seen.add(AtomicInt64(0))
        }
        let consumerFutures = ArrayList<Future<Unit>>()
        for (_ in 0..consumers) {
            consumerFutures.add(spawn {
                while (true) {
                    match (q.remove()) {
                        case Some(v) => seen[v].fetchAdd(1)
                        case None => break
                    }
                }
            })
        }
        for (f in producerFutures) {
            f.get()
        }
        for (f in consumerFutures) {
            f.get()
        }
        var received: Int64 = 0
        var duplicated: Int64 = 0
        for (i in 0..seen.size) {
            let n = seen[i].load()
            received += n
            if (n > 1) {
                duplicated++
            }
        }
        @Expect(received, producers * per)
        @Expect(duplicated, 0)
    }
}
