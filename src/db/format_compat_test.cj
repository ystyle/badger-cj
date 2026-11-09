package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.fs.*

/**
 * 2.0 打开 v1.6.22 数据目录（阶段 3.2 兼容验收）。
 *
 * 夹具见 tests/fixtures/v1.6.22/README.md：v1.6.22 生成，含两张 .sst、一个 vlog 段
 * 和一份未 flush 的 .mem（生成后 kill -9），覆盖「旧表读取 + vlog 指针 + WAL replay」。
 * 2.0 与 v1.6.x 字节语法相同（只改文件布局/物理大小），因此必须能直接打开、逐 key 读回。
 */
@Test
class FormatCompatTest {
    @TestCase
    func testOpenV162FixtureAndContinueWriting(): Unit {
        let fixture = "tests/fixtures/v1.6.22"
        let dir = "/tmp/badger_compat_v162"
        cleanupDir(dir)
        copyFixtureDir(fixture, dir)

        let opt = Config(dir: dir, memTableSize: 64 * 1024u64, valueThreshold: 1024u64)
        let db = Badger.open(opt)

        // inline 小值：flush 前写入 + 覆盖
        assertValue(db, "small-0", "value-0-second")
        assertValue(db, "small-1", "value-1")
        assertValue(db, "small-9", "value-9")

        // 大值：走 vlog 指针，跨版本读回
        assertBytes(db, "big-0", compatValue("big0", 2048))
        assertBytes(db, "big-1", compatValue("big1", 2048))

        // TTL 键仍有效（TTL 1 小时，生成时未过期）
        assertValue(db, "ttl-key", "ttl-value")

        // 删除标记必须生效（夹具里删除发生在第二次 flush 之后、未落盘 → 依赖 WAL replay）
        @Assert(db.get("del-me".toArray()).isNone(), true)

        // 未 flush 数据（只存在于 3.mem）→ 2.0 的 WAL replay 必须读回
        for (i in 0..5) {
            assertValue(db, "wal-${i}", "wal-${i}")
        }

        // 旧目录打开后补写 FORMAT 基线
        @Assert(exists(Path("${dir}/FORMAT")), true)
        @Assert(readFormat(dir).format, 1)

        // 继续写入并重开，验证目录已被 2.0 正常接管
        db.updateOrThrow({ txn => txn.set("new-key".toArray(), "new-value".toArray()) })
        db.close()

        let db2 = Badger.open(opt)
        assertValue(db2, "new-key", "new-value")
        assertValue(db2, "small-0", "value-0-second")
        assertBytes(db2, "big-0", compatValue("big0", 2048))
        @Assert(db2.get("del-me".toArray()).isNone(), true)
        db2.close()

        cleanupDir(dir)
    }
}

func copyFixtureDir(src: String, dst: String): Unit {
    if (!exists(Path(dst))) {
        Directory.create(dst, recursive: true)
    }
    for (e in Directory.readFrom(Path(src))) {
        let sp = "${src}/${e.name}"
        let dp = "${dst}/${e.name}"
        if (e.isDirectory()) {
            copyFixtureDir(sp, dp)
        } else {
            File.writeTo(Path(dp), File.readFrom(Path(sp)))
        }
    }
}

func compatValue(tag: String, size: Int64): Array<Byte> {
    let buf = Array<Byte>(size, repeat: 0x41)
    let tagBytes = tag.toArray()
    tagBytes.copyTo(buf, 0, 0, tagBytes.size)
    buf
}

func assertValue(db: Badger, key: String, expected: String): Unit {
    match (db.get(key.toArray())) {
        case Some(vs) => @Assert(String.fromUtf8(vs.value), expected)
        case None => @Fail("key ${key} 缺失")
    }
}

func assertBytes(db: Badger, key: String, expected: Array<Byte>): Unit {
    match (db.get(key.toArray())) {
        case Some(vs) => @Assert(vs.value, expected)
        case None => @Fail("key ${key} 缺失")
    }
}
