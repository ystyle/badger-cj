package badgercj.db
import std.collection.concurrent.*
// 编译探测 LinkedBlockingQueue 方法
public func probeLbq(): Unit {
    let q = LinkedBlockingQueue<Int64>(10)
    q.add(1)
    let _ = q.tryRemove()
    let _ = q.size
    let _ = q.peek()
    let _ = q.take()
    let _ = q.poll()
    let _ = q.remove()
    let _ = q.isEmpty()
}
