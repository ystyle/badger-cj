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
