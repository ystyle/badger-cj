package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*

/**
 * FORMAT 基线：2.0.0 起建库/首次打开写 `format=1`；更高版本或未知 feature 拒绝打开。
 * 文件缺失视为 v1.6.x（format 1），首次打开后补写——这是 2.0 能读 v1.6 数据目录的基础。
 */
@Test
class FormatTest {
    @TestCase
    func testNewDbWritesFormatBaseline(): Unit {
        let dir = "/tmp/badger_format_new"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))
        db.close()
        @Assert(exists(Path("${dir}/FORMAT")), true)
        let info = readFormat(dir)
        @Assert(info.format, 1)
        @Assert(info.features.isEmpty(), true)
        cleanupDir(dir)
    }

    @TestCase
    func testLegacyDirWithoutFormatIsAcceptedAndBackfilled(): Unit {
        let dir = "/tmp/badger_format_legacy"
        cleanupDir(dir)
        Directory.create(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64, disableWAL: true))
        db.close()
        @Assert(exists(Path("${dir}/FORMAT")), true)
        cleanupDir(dir)
    }

    @TestCase
    func testRejectsHigherFormat(): Unit {
        let dir = "/tmp/badger_format_higher"
        cleanupDir(dir)
        Directory.create(dir)
        writeFormatText(dir, "format=2\nfeatures=\n")
        var thrown = false
        try {
            Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))
            false
        } catch (e: Exception) {
            thrown = true
        }
        @Assert(thrown, true)
        cleanupDir(dir)
    }

    @TestCase
    func testRejectsUnknownFeature(): Unit {
        let dir = "/tmp/badger_format_feature"
        cleanupDir(dir)
        Directory.create(dir)
        writeFormatText(dir, "format=1\nfeatures=encryption-v1\n")
        var thrown = false
        try {
            Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))
            false
        } catch (e: Exception) {
            thrown = true
        }
        @Assert(thrown, true)
        cleanupDir(dir)
    }

    @TestCase
    func testRejectsCorruptFormat(): Unit {
        let dir = "/tmp/badger_format_corrupt"
        cleanupDir(dir)
        Directory.create(dir)
        writeFormatText(dir, "format=\n")
        var thrown = false
        try {
            Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))
            false
        } catch (e: Exception) {
            thrown = true
        }
        @Assert(thrown, true)
        cleanupDir(dir)
    }
}

func writeFormatText(dir: String, text: String): Unit {
    let f = File(Path("${dir}/FORMAT"), OpenMode.Write)
    try {
        f.write(text.toArray())
        f.flush()
    } finally {
        f.close()
    }
}
