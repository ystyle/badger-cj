package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.fs.*
import std.io.*
import badgercj.table.*

/**
 * allVersions 语义：删除/过期条目必须被产出（与 go badger 一致）。
 *
 * 旧实现无论 allVersions 与否都跳过 tombstone：
 * - MergeOperator 的「删除优先」失效（看不到删除就无法终止折叠）；
 * - Backup 走 allVersions 流 → 备份丢删除、恢复后旧值复活。
 */
@Test
class AllVersionsTombstoneTest {
    @TestCase
    func testAllVersionsIteratorYieldsTombstone(): Unit {
        let dir = "/tmp/badger_allversions_tombstone"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))

        db.updateOrThrow({ txn => txn.set("k".toArray(), "v1".toArray()) })
        db.updateOrThrow({ txn => txn.delete("k".toArray()) })

        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator(opt: IteratorOptions(allVersions: true))
        var sawValue = false
        var sawTombstone = false
        iter.rewind()
        while (iter.valid()) {
            let item = iter.item()
            if (item.keyCopy() == "k".toArray()) {
                if (item.isDeletedOrExpired()) {
                    sawTombstone = true
                } else {
                    sawValue = true
                }
            }
            iter.next()
        }
        iter.close()
        txn.discard()
        db.close()
        cleanupDir(dir)

        @Assert(sawValue, true)
        @Assert(sawTombstone, true)
    }

    @TestCase
    func testDefaultIteratorHidesTombstone(): Unit {
        let dir = "/tmp/badger_allversions_default"
        cleanupDir(dir)
        let db = Badger.open(Config(dir: dir, memTableSize: 64 * 1024u64))

        db.updateOrThrow({ txn => txn.set("k".toArray(), "v1".toArray()) })
        db.updateOrThrow({ txn => txn.delete("k".toArray()) })

        let txn = db.newTransaction(update: false)
        let iter = txn.newIterator()
        iter.rewind()
        @Assert(iter.valid(), false)
        iter.close()
        txn.discard()
        db.close()
        cleanupDir(dir)
    }

    @TestCase
    func testBackupRestoreKeepsDeletion(): Unit {
        let srcDir = "/tmp/badger_allversions_backup_src"
        let dstDir = "/tmp/badger_allversions_backup_dst"
        let backupDir = "/tmp/badger_allversions_backup_file"
        cleanupDir(srcDir)
        cleanupDir(dstDir)
        cleanupDir(backupDir)
        Directory.create(backupDir)

        let srcCfg = Config(dir: srcDir, memTableSize: 64 * 1024u64, disableWAL: true)
        let db = Badger.open(srcCfg)
        db.updateOrThrow({ txn =>
            txn.set("keep".toArray(), "k1".toArray())
            txn.set("gone".toArray(), "g1".toArray())
        })
        db.updateOrThrow({ txn => txn.delete("gone".toArray()) })

        let backupPath = "${backupDir}/backup.data"
        let file = File(backupPath, OpenMode.Write)
        let _ = db.Backup(file)
        file.close()
        db.close()
        cleanupDir(srcDir)
        @Assert(FileInfo(backupPath).size > 13, true)

        let db2 = Badger.open(Config(dir: dstDir, memTableSize: 64 * 1024u64, disableWAL: true))
        let restoreFile = File(backupPath, OpenMode.Read)
        db2.Restore(restoreFile)

        let keep = db2.view({ txn => txn.get("keep".toArray()) })
        let gone = db2.view({ txn => txn.get("gone".toArray()) })
        db2.close()
        cleanupDir(dstDir)
        cleanupDir(backupDir)

        @Assert(keep.isSome(), true)
        // 删除必须随备份/恢复保留；旧值不得复活
        @Assert(gone.isNone(), true)
    }
}
