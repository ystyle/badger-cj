package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.time.*

@Test
class WaterMarkTest {
    @TestCase
    func testWaterMarkInit() {
        let wm = WaterMark("test")
        @Assert(wm.doneUntil(), 0)
        @Assert(wm.lastIndex(), 0)
        wm.stop()
    }
    
    @TestCase
    func testWaterMarkBegin() {
        let wm = WaterMark("test")
        wm.begin(10)
        
        sleep(Duration.millisecond * 50)
        
        @Assert(wm.lastIndex(), 10)
        wm.stop()
    }
    
    @TestCase
    func testWaterMarkDone() {
        let wm = WaterMark("test")
        
        wm.begin(1)
        wm.done(1)
        
        sleep(Duration.millisecond * 50)
        @Assert(wm.doneUntil(), 1)
        
        wm.begin(2)
        wm.done(2)
        sleep(Duration.millisecond * 50)
        @Assert(wm.doneUntil(), 2)
        
        wm.begin(3)
        wm.done(3)
        sleep(Duration.millisecond * 50)
        @Assert(wm.doneUntil(), 3)
        
        wm.stop()
    }
    
    @TestCase
    func testWaterMarkOutOfOrder() {
        let wm = WaterMark("test")
        
        wm.begin(3)
        wm.begin(1)
        wm.begin(2)
        
        wm.done(3)
        sleep(Duration.millisecond * 50)
        @Assert(wm.doneUntil(), 0) // 1 和 2 还未完成
        
        wm.done(1)
        sleep(Duration.millisecond * 50)
        @Assert(wm.doneUntil(), 1)
        
        wm.done(2)
        sleep(Duration.millisecond * 50)
        @Assert(wm.doneUntil(), 3) // 1, 2, 3 都完成了
        
        wm.stop()
    }
    
    @TestCase
    func testWaterMarkBeginMany() {
        let wm = WaterMark("test")
        
        wm.beginMany([1, 2, 3])
        wm.doneMany([1, 2, 3])
        
        sleep(Duration.millisecond * 50)
        @Assert(wm.doneUntil(), 3)
        
        wm.stop()
    }
    
    @TestCase
    func testWaterMarkSetDoneUntil() {
        let wm = WaterMark("test")
        
        wm.setDoneUntil(10)
        @Assert(wm.doneUntil(), 10)
        
        wm.stop()
    }
}

// 回归：pending 必须是计数（同一 readTs 会被并发读事务共享）。
// 用集合时「读事务 begin(1)、写事务 begin(1)、写事务 done(1)」会移除读事务的登记，
// doneUntil 提前推进 → compaction 按错误水位丢弃仍被读事务需要的版本。
@Test
class WatermarkMultisetTest {
    @TestCase
    func testSameTsMultipleHolders() {
        let wm = WaterMark("test.shared")
        wm.begin(1u64)
        wm.begin(1u64)
        wm.done(1u64)
        @Assert(wm.doneUntil(), 0u64)
        wm.done(1u64)
        @Assert(wm.doneUntil(), 1u64)
        wm.stop()
    }

    @TestCase
    func testContiguousAdvance() {
        let wm = WaterMark("test.contiguous")
        var i: UInt64 = 0
        while (i < 4) {
            wm.begin(i)
            i++
        }
        wm.done(0u64)
        wm.done(2u64)
        @Assert(wm.doneUntil(), 0u64)
        wm.done(1u64)
        @Assert(wm.doneUntil(), 2u64)
        wm.done(3u64)
        @Assert(wm.doneUntil(), 3u64)
        wm.stop()
    }
}
