package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import badgercj.table.*

@Test
class LevelsTest {
    
    @TestCase
    func testLevelHandlerAddTable(): Unit {
        let handler = LevelHandler(0)
        
        let entries = ArrayList<(Array<Byte>, ValueStruct)>()
        entries.add(([0x01, 0x02], ValueStruct([0x01])))
        
        let table = MockTable(1, entries)
        handler.addTable(table)
        
        @Assert(handler.numTables() == 1)
    }
    
    @TestCase
    func testLevelHandlerGetL0(): Unit {
        let handler = LevelHandler(0)
        
        let entries = ArrayList<(Array<Byte>, ValueStruct)>()
        entries.add(([0x01], ValueStruct([0x61])))
        entries.add(([0x02], ValueStruct([0x62])))
        
        let table = MockTable(1, entries)
        handler.addTable(table)
        
        let result = handler.get([0x01], 0)
        if (let Some(v) <- result) {
            @Assert(v.value[0] == 0x61)
        } else {
            @Fail("Should find key")
        }
    }
    
    @TestCase
    func testLevelsControllerMultiLevel(): Unit {
        let controller = LevelsController()
        
        let entries1 = ArrayList<(Array<Byte>, ValueStruct)>()
        entries1.add(([0x01], ValueStruct([0x61])))
        let table1 = MockTable(1, entries1)
        
        let entries2 = ArrayList<(Array<Byte>, ValueStruct)>()
        entries2.add(([0x02], ValueStruct([0x62])))
        let table2 = MockTable(2, entries2)
        
        controller.addTable(0, table1)
        controller.addTable(1, table2)
        
        @Assert(controller.getLevelHandler(0).numTables() == 1)
        @Assert(controller.getLevelHandler(1).numTables() == 1)
    }
    
    @TestCase
    func testLevelsControllerGetFromMultipleLevels(): Unit {
        let controller = LevelsController()
        
        let entries1 = ArrayList<(Array<Byte>, ValueStruct)>()
        entries1.add(([0x01], ValueStruct([0x61])))
        let table1 = MockTable(1, entries1)
        
        let entries2 = ArrayList<(Array<Byte>, ValueStruct)>()
        entries2.add(([0x02], ValueStruct([0x62])))
        let table2 = MockTable(2, entries2)
        
        controller.addTable(0, table1)
        controller.addTable(1, table2)
        
        let result1 = controller.get([0x01], 0)
        if (let Some(v) <- result1) {
            @Assert(v.value[0] == 0x61)
        } else {
            @Fail("Should find key 0x01")
        }
        
        let result2 = controller.get([0x02], 0)
        if (let Some(v) <- result2) {
            @Assert(v.value[0] == 0x62)
        } else {
            @Fail("Should find key 0x02")
        }
    }
    
    @TestCase
    func testLevelHandlerNotFound(): Unit {
        let handler = LevelHandler(0)
        
        let entries = ArrayList<(Array<Byte>, ValueStruct)>()
        entries.add(([0x01], ValueStruct([0x61])))
        
        let table = MockTable(1, entries)
        handler.addTable(table)
        
        let result = handler.get([0x99], 0)
        if (let Some(v) <- result) {
            @Fail("Should not find key")
        }
    }
}

main(): Int64 {
    0
}
