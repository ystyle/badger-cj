package badgercj.io_uring

/**
 * io_uring 测试
 */

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*

@Test
class IoUringTest {
    
    @TestCase
    func testCreateAndClose() {
        // 检查是否在 Linux 上
        if (!isLinuxPlatform()) {
            println("Skipping: not on Linux platform")
            return
        }
        
        let ring = IoUring(entries: 16)
        @Assert(ring.isClosed(), false)
        
        ring.close()
        @Assert(ring.isClosed(), true)
    }
    
    @TestCase
    func testSubmit() {
        if (!isLinuxPlatform()) {
            return
        }
        
        let ring = IoUring(entries: 16)
        
        unsafe {
            let sqe = io_uring_get_sqe(ring.getRingPtr())
            ioUringPrepNop(sqe)
            sqeSetUserData(sqe, 123u64)
        }
        
        ring.submit()
        
        unsafe {
            let cqePtrPtr = LibC.malloc<CPointer<Unit>>(count: 1)
            let ret = __io_uring_get_cqe(ring.getRingPtr(), cqePtrPtr, 1, 1, CPointer<Unit>())
            @Assert(ret, 0)
            
            let cqe = cqePtrPtr.read()
            LibC.free(cqePtrPtr)
            
            let data = cqeGetUserData(cqe)
            @Assert(data, 123u64)
            
            let res = cqeGetRes(cqe)
            @Assert(res, 0)
            
            ioUringCqeSeen(ring.getRingPtr(), cqe)
        }
        
        ring.close()
    }
    
    @TestCase
    func testCreateIoUringWriter() {
        let writer = createIoUringWriter("/tmp/test_io_uring_interface")
        match (writer) {
            case Some(w) => 
                println("io_uring writer created successfully")
                w.close()
            case None => 
                println("io_uring not available on this platform")
        }
    }
}

@Test
class IoUringFileWriterTest {
    
    @TestCase
    func testWriteAndSync() {
        if (!isLinuxPlatform()) {
            return
        }
        
        let testDir = "/tmp/io_uring_test"
        let testFile = "${testDir}/test.txt"
        
        cleanupTestDir(testDir)
        Directory.create(Path(testDir))
        
        let writer = IoUringFileWriter(testFile, entries: 16)
        
        writer.write("Hello".toArray())
        writer.write(" World".toArray())
        writer.sync()
        writer.close()
        
        let content = readFile(testFile)
        @Assert(content, "Hello World")
        
        cleanupTestDir(testDir)
    }
    
    @TestCase
    func testMultipleWrites() {
        if (!isLinuxPlatform()) {
            return
        }
        
        let testDir = "/tmp/io_uring_test2"
        let testFile = "${testDir}/multi.txt"
        
        cleanupTestDir(testDir)
        Directory.create(Path(testDir))
        
        let writer = IoUringFileWriter(testFile, entries: 16)
        
        for (i in 0..20) {
            writer.write("line${i}\n".toArray())
        }
        writer.close()
        
        let content = readFile(testFile)
        @Assert(content.contains("line0"), true)
        @Assert(content.contains("line19"), true)
        
        cleanupTestDir(testDir)
    }
    
    private func readFile(path: String): String {
        let data = File.readFrom(Path(path))
        String.fromUtf8(data)
    }
    
    private func cleanupTestDir(path: String) {
        if (exists(Path(path))) {
            remove(Path(path), recursive: true)
        }
    }
}

// 平台检查辅助函数
@When[os == "Linux"]
private func isLinuxPlatform(): Bool { true }

@When[os != "Linux"]
private func isLinuxPlatform(): Bool { false }