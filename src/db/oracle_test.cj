package badgercj.db

import std.unittest.*
import std.unittest.testmacro.*
import std.sync.*
import std.time.*
import std.collection.*

@Test
class OracleTest {
    @TestCase
    func testOracleReadTs() {
        let oracle = Oracle()
        
        let ts1 = oracle.readTs()
        let ts2 = oracle.readTs()
        
        @Assert(ts1, 0)
        @Assert(ts2 >= ts1, true)
        
        oracle.stop()
    }
    
    @TestCase
    func testOracleNewCommitTs() {
        let oracle = Oracle()
        
        let readTs = oracle.readTs()
        var txn = TxnState(readTs)
        
        let commitTs = oracle.newCommitTs(txn)
        @Assert(commitTs >= readTs, true)
        
        oracle.doneCommit(commitTs)
        oracle.stop()
    }
    
    @TestCase
    func testOracleNoConflict() {
        let oracle = Oracle()
        
        let readTs1 = oracle.readTs()
        var txn1 = TxnState(readTs1)
        txn1.conflictKeys.add(100)
        txn1.conflictKeys.add(200)
        
        let commitTs1 = oracle.newCommitTs(txn1)
        oracle.doneCommit(commitTs1)
        
        sleep(Duration.millisecond * 50)
        
        let readTs2 = oracle.readTs()
        var txn2 = TxnState(readTs2)
        txn2.conflictKeys.add(300)
        txn2.conflictKeys.add(400)
        
        let commitTs2 = oracle.newCommitTs(txn2)
        oracle.doneCommit(commitTs2)
        
        @Assert(commitTs2 > commitTs1, true)
        
        oracle.stop()
    }
    
    @TestCase
    func testOracleConflict() {
        let oracle = Oracle()
        
        let readTs1 = oracle.readTs()
        var txn1 = TxnState(readTs1)
        txn1.conflictKeys.add(100)
        txn1.conflictKeys.add(200)
        txn1.reads.add(50)
        
        let commitTs1 = oracle.newCommitTs(txn1)
        oracle.doneCommit(commitTs1)
        
        sleep(Duration.millisecond * 50)
        
        let readTs2 = oracle.readTs()
        var txn2 = TxnState(readTs2)
        txn2.conflictKeys.add(150)
        txn2.reads.add(100)
        
        var conflictDetected = false
        try {
            oracle.newCommitTs(txn2)
        } catch (e: TxnConflict) {
            conflictDetected = true
        }
        
        @Assert(conflictDetected, true)
        
        oracle.stop()
    }
    
    @TestCase
    func testOracleCleanup() {
        let oracle = Oracle()
        
        for (i in 0..10) {
            let readTs = oracle.readTs()
            let txn = TxnState(readTs)
            txn.conflictKeys.add(UInt64(i))
            
            let commitTs = oracle.newCommitTs(txn)
            oracle.doneCommit(commitTs)
        }
        
        sleep(Duration.millisecond * 100)
        
        oracle.stop()
    }
    
    @TestCase
    func testOracleDoneCommit() {
        let oracle = Oracle()
        
        let readTs = oracle.readTs()
        let txn = TxnState(readTs)
        txn.conflictKeys.add(UInt64(1))
        
        let commitTs = oracle.newCommitTs(txn)
        oracle.doneCommit(commitTs)
        
        sleep(Duration.millisecond * 50)
        @Assert(oracle.nextTs() > commitTs, true)
        
        oracle.stop()
    }
    
    @TestCase
    func testOracleMultipleTransactions() {
        let oracle = Oracle()
        
        let commits = ArrayList<UInt64>()
        
        for (i in 0..5) {
            let readTs = oracle.readTs()
            let txn = TxnState(readTs)
            txn.conflictKeys.add(UInt64(i * 10))
            
            let commitTs = oracle.newCommitTs(txn)
            oracle.doneCommit(commitTs)
            commits.add(commitTs)
        }
        
        for (i in 1..5) {
            @Assert(commits[i] > commits[i - 1], true)
        }
        
        oracle.stop()
    }
    
    @TestCase
    func testOracleManagedMode() {
        let oracle = Oracle(isManaged: true)
        
        var txn = TxnState(0)
        txn.commitTs = 100
        
        let commitTs = oracle.newCommitTs(txn)
        @Assert(commitTs, 100)
        
        oracle.stop()
    }
    
    @TestCase
    func testOracleNoConflictDetection() {
        let oracle = Oracle(detectConflicts: false)
        
        let readTs1 = oracle.readTs()
        var txn1 = TxnState(readTs1)
        txn1.conflictKeys.add(100)
        txn1.reads.add(100)
        
        let commitTs1 = oracle.newCommitTs(txn1)
        oracle.doneCommit(commitTs1)
        
        sleep(Duration.millisecond * 50)
        
        let readTs2 = oracle.readTs()
        var txn2 = TxnState(readTs2)
        txn2.conflictKeys.add(100)
        txn2.reads.add(100)
        
        var noError = true
        try {
            let commitTs2 = oracle.newCommitTs(txn2)
            oracle.doneCommit(commitTs2)
        } catch (e: TxnConflict) {
            noError = false
        }
        
        @Assert(noError, true)
        
        oracle.stop()
    }
}
