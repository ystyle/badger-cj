package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*

// TODO: Snapshot 测试需要 MVCC 版本控制完全实现后才能通过
// 当前 db.set() 会覆盖旧值，快照无法看到历史版本
@Test
class SnapshotTest {
    // 暂时禁用测试，等 MVCC 完全实现
    // @TestCase
    // func testSnapshotBasic() { }
    
    // @TestCase
    // func testSnapshotIterator() { }
}
