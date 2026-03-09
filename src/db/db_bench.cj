package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.random.*

func dbBenchKey(i: Int64): Array<Byte> {
    let s = i.toString()
    let padLen = 16 - s.size
    return "key${"0" * padLen}${s}".toArray()
}

@Test
class DBBench {
    
    private var db: DB
    
    public init() {
        let dbDir = "/tmp/badger_bench_${Random(42).nextInt64(1000000)}"
        db = DB.open(DBOptions(dir: dbDir))
        
        for (i in 0..100) {
            let key = dbBenchKey(i)
            let value = Array<Byte>(64, { _ => 65 })
            db.set(key, value)
        }
    }
    
    @Bench
    func benchDBSet() {
        let key = dbBenchKey(Random(42).nextInt64(100))
        let value = Array<Byte>(64, { _ => 65 })
        db.set(key, value)
    }
    
    @Bench
    func benchDBGet() {
        let key = dbBenchKey(Random(42).nextInt64(100))
        db.get(key)
    }
}
