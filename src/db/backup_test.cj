package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.fs.*
import std.time.*
import std.io.*
import badgercj.table.*

@Test
class BackupTest {
    
    @TestCase
    func testBackupRestore(): Unit {
        let testDir = "/tmp/badger_backup_test_${DateTime.now().hashCode()}"
        let backupDir = "/tmp/badger_backup_file_${DateTime.now().hashCode()}"
        BackupTest.cleanupTestDir(testDir)
        BackupTest.cleanupTestDir(backupDir)
        Directory.create(backupDir)
        
        let config = Config(dir: testDir, memTableSize: 64 * 1024u64, disableWAL: true, valueThreshold: 1024 * 1024u64)
        let db = Badger.open(config)
        
        db.update { txn =>
            txn.set("key1".toArray(), "value1".toArray())
            txn.set("key2".toArray(), "value2".toArray())
            txn.set("key3".toArray(), "value3".toArray())
        }
        
        let backupPath = "${backupDir}/backup.data"
        let file = File(backupPath, OpenMode.Write)
        let version = db.Backup(file)
        
        @Assert(version > 0)
        
        db.close()
        
        BackupTest.cleanupTestDir(testDir)
        
        let db2 = Badger.open(config)
        
        let restoreFile = File(backupPath, OpenMode.Read)
        db2.Restore(restoreFile)
        
        let v1 = db2.view { txn => txn.get("key1".toArray()) }
        let v2 = db2.view { txn => txn.get("key2".toArray()) }
        let v3 = db2.view { txn => txn.get("key3".toArray()) }
        
        @Assert(v1.isSome())
        @Assert(v2.isSome())
        @Assert(v3.isSome())
        
        db2.close()
        BackupTest.cleanupTestDir(testDir)
        BackupTest.cleanupTestDir(backupDir)
    }
    
    @TestCase
    func testBackupWithTTL(): Unit {
        let testDir = "/tmp/badger_backup_ttl_${DateTime.now().hashCode()}"
        let backupDir = "/tmp/badger_backup_ttl_file_${DateTime.now().hashCode()}"
        BackupTest.cleanupTestDir(testDir)
        BackupTest.cleanupTestDir(backupDir)
        Directory.create(backupDir)
        
        let config = Config(dir: testDir, memTableSize: 64 * 1024u64, disableWAL: true, valueThreshold: 1024 * 1024u64)
        let db = Badger.open(config)
        
        db.update { txn =>
            let entry = Entry.new("ttl_key".toArray(), "ttl_value".toArray())
                .withTTL(Duration.second * 3600)
            txn.setEntry(entry)
        }
        
        let backupPath = "${backupDir}/backup_ttl.data"
        let file = File(backupPath, OpenMode.Write)
        let _ = db.Backup(file)
        
        db.close()
        
        BackupTest.cleanupTestDir(testDir)
        
        let db2 = Badger.open(config)
        
        let restoreFile = File(backupPath, OpenMode.Read)
        db2.Restore(restoreFile)
        
        let restored = db2.view { txn => txn.get("ttl_key".toArray()) }
        @Assert(restored.isSome())
        
        db2.close()
        BackupTest.cleanupTestDir(testDir)
        BackupTest.cleanupTestDir(backupDir)
    }
    
    @TestCase
    func testIncrementalBackup(): Unit {
        let testDir = "/tmp/badger_backup_inc_${DateTime.now().hashCode()}"
        let backupDir = "/tmp/badger_backup_inc_file_${DateTime.now().hashCode()}"
        BackupTest.cleanupTestDir(testDir)
        BackupTest.cleanupTestDir(backupDir)
        Directory.create(backupDir)
        
        let config = Config(dir: testDir, memTableSize: 64 * 1024u64, disableWAL: true, valueThreshold: 1024 * 1024u64)
        let db = Badger.open(config)
        
        db.update { txn =>
            txn.set("key1".toArray(), "value1".toArray())
        }
        
        let backupPath1 = "${backupDir}/backup1.data"
        let file1 = File(backupPath1, OpenMode.Write)
        let version1 = db.Backup(file1)
        
        db.update { txn =>
            txn.set("key2".toArray(), "value2".toArray())
        }
        
        let backupPath2 = "${backupDir}/backup2.data"
        let file2 = File(backupPath2, OpenMode.Write)
        let version2 = db.Backup(file2, since: version1 + 1)
        
        @Assert(version2 > version1)
        
        db.close()
        
        BackupTest.cleanupTestDir(testDir)
        
        let db2 = Badger.open(config)
        
        let restoreFile2 = File(backupPath2, OpenMode.Read)
        db2.Restore(restoreFile2)
        
        let v1 = db2.view { txn => txn.get("key1".toArray()) }
        let v2 = db2.view { txn => txn.get("key2".toArray()) }
        
        @Assert(v1.isNone())
        @Assert(v2.isSome())
        
        db2.close()
        BackupTest.cleanupTestDir(testDir)
        BackupTest.cleanupTestDir(backupDir)
    }
    
    @TestCase
    func testBackupEmptyDB(): Unit {
        let testDir = "/tmp/badger_backup_empty_${DateTime.now().hashCode()}"
        let backupDir = "/tmp/badger_backup_empty_file_${DateTime.now().hashCode()}"
        BackupTest.cleanupTestDir(testDir)
        BackupTest.cleanupTestDir(backupDir)
        Directory.create(backupDir)
        
        let config = Config(dir: testDir, memTableSize: 64 * 1024u64, disableWAL: true, valueThreshold: 1024 * 1024u64)
        let db = Badger.open(config)
        
        let backupPath = "${backupDir}/backup_empty.data"
        let file = File(backupPath, OpenMode.Write)
        let version = db.Backup(file)
        
        @Assert(version == 0)
        
        db.close()
        
        BackupTest.cleanupTestDir(testDir)
        
        let db2 = Badger.open(config)
        
        let restoreFile = File(backupPath, OpenMode.Read)
        db2.Restore(restoreFile)
        
        let v = db2.view { txn => txn.get("any_key".toArray()) }
        @Assert(v.isNone())
        
        db2.close()
        BackupTest.cleanupTestDir(testDir)
        BackupTest.cleanupTestDir(backupDir)
    }
    
    @TestCase
    func testBackupWithUserMeta(): Unit {
        let testDir = "/tmp/badger_backup_meta_${DateTime.now().hashCode()}"
        let backupDir = "/tmp/badger_backup_meta_file_${DateTime.now().hashCode()}"
        BackupTest.cleanupTestDir(testDir)
        BackupTest.cleanupTestDir(backupDir)
        Directory.create(backupDir)
        
        let config = Config(dir: testDir, memTableSize: 64 * 1024u64, disableWAL: true, valueThreshold: 1024 * 1024u64)
        let db = Badger.open(config)
        
        db.update { txn =>
            let entry = Entry.new("meta_key".toArray(), "meta_value".toArray())
                .withMeta(0x42)
            txn.setEntry(entry)
        }
        
        let backupPath = "${backupDir}/backup_meta.data"
        let file = File(backupPath, OpenMode.Write)
        let _ = db.Backup(file)
        
        db.close()
        
        BackupTest.cleanupTestDir(testDir)
        
        let db2 = Badger.open(config)
        
        let restoreFile = File(backupPath, OpenMode.Read)
        db2.Restore(restoreFile)
        
        let val = db2.view { txn => txn.get("meta_key".toArray()) }
        @Assert(val.isSome())
        @Assert(val.getOrThrow() == "meta_value".toArray())
        
        db2.close()
        BackupTest.cleanupTestDir(testDir)
        BackupTest.cleanupTestDir(backupDir)
    }
    
    static func cleanupTestDir(path: String): Unit {
        if (exists(path)) {
            try {
                remove(path, recursive: true)
            } catch (_) {}
        }
    }
    
    @TestCase
    func testRestoreWithWALRecovery(): Unit {
        let testDir = "/tmp/badger_backup_wal_${DateTime.now().hashCode()}"
        let backupDir = "/tmp/badger_backup_wal_file_${DateTime.now().hashCode()}"
        BackupTest.cleanupTestDir(testDir)
        BackupTest.cleanupTestDir(backupDir)
        Directory.create(backupDir)
        
        // 使用 WAL（不设置 disableWAL）
        let config = Config(dir: testDir, memTableSize: 64 * 1024u64)
        let db = Badger.open(config)
        
        db.update { txn =>
            txn.set("wal_key1".toArray(), "wal_value1".toArray())
            txn.set("wal_key2".toArray(), "wal_value2".toArray())
        }
        
        let backupPath = "${backupDir}/backup_wal.data"
        let file = File(backupPath, OpenMode.Write)
        let _ = db.Backup(file)
        
        db.close()
        BackupTest.cleanupTestDir(testDir)
        
        // Restore 到新数据库
        let db2 = Badger.open(config)
        
        let restoreFile = File(backupPath, OpenMode.Read)
        db2.Restore(restoreFile)
        
        // 验证数据存在
        let v1 = db2.view { txn => txn.get("wal_key1".toArray()) }
        let v2 = db2.view { txn => txn.get("wal_key2".toArray()) }
        @Assert(v1.isSome())
        @Assert(v2.isSome())
        
        // 不调用 close()，模拟崩溃
        // 直接重新打开，验证 WAL 恢复
        let db3 = Badger.open(config)
        
        let v3 = db3.view { txn => txn.get("wal_key1".toArray()) }
        let v4 = db3.view { txn => txn.get("wal_key2".toArray()) }
        
        @Assert(v3.isSome())
        @Assert(v4.isSome())
        
        db3.close()
        BackupTest.cleanupTestDir(testDir)
        BackupTest.cleanupTestDir(backupDir)
    }
}