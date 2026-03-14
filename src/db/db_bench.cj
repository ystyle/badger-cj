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
    
    private var db: ?Badger = None
    private var dbDir: String = ""
    private var key: Array<Byte> = []
    private var value: Array<Byte> = []
    
    public init() {}
    
    @BeforeAll
    func setup() {
        dbDir = "/tmp/badger_bench_${Random(42).nextInt64(1000000)}"
        db = Badger.open(Config(dir: dbDir))
        
        key = dbBenchKey(0)
        value = Array<Byte>(64, { _ => 65 })
        
        for (i in 0..100) {
            let k = dbBenchKey(i)
            if (let Some(d) <- db) {
                d.set(k, value)
            }
        }
    }
    
    @Bench
    func benchDBSet() {
        if (let Some(d) <- db) {
            d.set(key, value)
        }
    }
    
    @Bench
    func benchDBGet() {
        if (let Some(d) <- db) {
            d.get(key)
        }
    }
    
    @AfterAll
    func cleanup() {
        if (let Some(d) <- db) {
            d.close()
        }
        if (exists(Path(dbDir))) {
            remove(Path(dbDir), recursive: true)
        }
    }
}
