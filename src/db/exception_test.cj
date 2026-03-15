package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*

@Test
class ExceptionTest {
    @TestCase
    func testErrorCode() {
        let e = BadgerException.databaseClosed()
        @Assert(e.code == ErrorCode.DatabaseClosed)
    }
    
    @TestCase
    func testExceptionMessage() {
        let e = BadgerException.conflictDetected()
        @Assert(e.message.contains("conflict"))
    }
    
    @TestCase
    func testInvalidConfig() {
        let e = BadgerException.invalidConfig("bad dir")
        @Assert(e.code == ErrorCode.InvalidConfig)
        @Assert(e.message.contains("bad dir"))
    }
    
    @TestCase
    func testDatabaseClosed() {
        let e = BadgerException.databaseClosed()
        @Assert(e.code == ErrorCode.DatabaseClosed)
        @Assert(e.message.contains("closed"))
    }
    
    @TestCase
    func testTransactionDiscarded() {
        let e = BadgerException.transactionDiscarded()
        @Assert(e.code == ErrorCode.TransactionDiscarded)
        @Assert(e.message.contains("discarded"))
    }
    
    @TestCase
    func testTransactionCommitted() {
        let e = BadgerException.transactionCommitted()
        @Assert(e.code == ErrorCode.TransactionCommitted)
        @Assert(e.message.contains("committed"))
    }
    
    @TestCase
    func testReadOnlyTransaction() {
        let e = BadgerException.readOnlyTransaction()
        @Assert(e.code == ErrorCode.ReadOnlyTransaction)
        @Assert(e.message.contains("read-only"))
    }
    
    @TestCase
    func testKeyNotFound() {
        let e = BadgerException.keyNotFound()
        @Assert(e.code == ErrorCode.KeyNotFound)
        @Assert(e.message.contains("not found"))
    }
    
    @TestCase
    func testIOError() {
        let e = BadgerException.ioError("file not accessible")
        @Assert(e.code == ErrorCode.IOError)
        @Assert(e.message.contains("file not accessible"))
    }
    
    @TestCase
    func testCorruptionError() {
        let e = BadgerException.corruptionError("checksum mismatch")
        @Assert(e.code == ErrorCode.CorruptionError)
        @Assert(e.message.contains("checksum mismatch"))
    }
    
    @TestCase
    func testExceptionInheritsFromException() {
        let e = BadgerException.databaseClosed()
        @Assert(e.message.size > 0)
    }
}