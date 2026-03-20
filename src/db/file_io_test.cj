package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.io.*
import std.time.*

/**
 * 文件写入工具测试
 */
@Test
class FileIOTest {
    
    @TestCase
    public func testWriteFileWithIoUring(): Unit {
        let testDir = "/tmp/badger_io_test_${DateTime.now().hashCode()}"
        let testPath = "${testDir}/test.sst"
        
        try {
            Directory.create(Path(testDir), recursive: true)
            
            let data: Array<Byte> = [1, 2, 3, 4, 5, 6, 7, 8]
            let written = writeFile(testPath, data, useIoUring: true)
            
            @Assert(written == 8)
            
            let readData = File.readFrom(Path(testPath))
            
            @Assert(readData.size == 8)
            @Assert(readData[0] == 1)
            @Assert(readData[7] == 8)
        } finally {
            cleanupDir(testDir)
        }
    }
    
    @TestCase
    public func testWriteFileSync(): Unit {
        let testDir = "/tmp/badger_io_test_sync_${DateTime.now().hashCode()}"
        let testPath = "${testDir}/test.sst"
        
        try {
            Directory.create(Path(testDir), recursive: true)
            
            let data: Array<Byte> = [10, 20, 30, 40]
            let written = writeFile(testPath, data, useIoUring: false)
            
            @Assert(written == 4)
            
            let readData = File.readFrom(Path(testPath))
            
            @Assert(readData.size == 4)
            @Assert(readData[0] == 10)
        } finally {
            cleanupDir(testDir)
        }
    }
    
    @TestCase
    public func testSyncWriteFile(): Unit {
        let testDir = "/tmp/badger_io_test_sync2_${DateTime.now().hashCode()}"
        let testPath = "${testDir}/test.sst"
        
        try {
            Directory.create(Path(testDir), recursive: true)
            
            let data: Array<Byte> = [100, 101, 102]
            let written = syncWriteFile(testPath, data)
            
            @Assert(written == 3)
            
            let readData = File.readFrom(Path(testPath))
            
            @Assert(readData.size == 3)
            @Assert(readData[0] == 100)
        } finally {
            cleanupDir(testDir)
        }
    }
    
    @TestCase
    public func testWriteLargeFile(): Unit {
        let testDir = "/tmp/badger_io_test_large_${DateTime.now().hashCode()}"
        let testPath = "${testDir}/test.sst"
        
        try {
            Directory.create(Path(testDir), recursive: true)
            
            let data = Array<Byte>(64 * 1024, {i => UInt8(i % 256)})
            let written = writeFile(testPath, data, useIoUring: true)
            
            @Assert(written == 64 * 1024)
            
            let readData = File.readFrom(Path(testPath))
            
            @Assert(readData.size == 64 * 1024)
            @Assert(readData[0] == 0)
            @Assert(readData[255] == 255)
            @Assert(readData[256] == 0)
        } finally {
            cleanupDir(testDir)
        }
    }
    
    @TestCase
    public func testConfigUseIoUring(): Unit {
        let config1 = Config(dir: "/tmp/test", useIoUring: true)
        @Assert(config1.UseIoUring == true)
        
        let config2 = Config(dir: "/tmp/test", useIoUring: false)
        @Assert(config2.UseIoUring == false)
        
        let config3 = Config(dir: "/tmp/test")
        @Assert(config3.UseIoUring == true)
        
        let config4 = config1.withUseIoUring(false)
        @Assert(config4.UseIoUring == false)
    }
}