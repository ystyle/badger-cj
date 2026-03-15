package badgercj.db

public enum ErrorCode {
    | DatabaseClosed
    | TransactionDiscarded
    | TransactionCommitted
    | ReadOnlyTransaction
    | ConflictDetected
    | KeyNotFound
    | IOError
    | CorruptionError
    | InvalidConfig
    
    public operator func ==(other: ErrorCode): Bool {
        match ((this, other)) {
            case (DatabaseClosed, DatabaseClosed) => true
            case (TransactionDiscarded, TransactionDiscarded) => true
            case (TransactionCommitted, TransactionCommitted) => true
            case (ReadOnlyTransaction, ReadOnlyTransaction) => true
            case (ConflictDetected, ConflictDetected) => true
            case (KeyNotFound, KeyNotFound) => true
            case (IOError, IOError) => true
            case (CorruptionError, CorruptionError) => true
            case (InvalidConfig, InvalidConfig) => true
            case _ => false
        }
    }
}

public class BadgerException <: Exception {
    public let code: ErrorCode
    
    public init(code: ErrorCode, message: String) {
        super(message)
        this.code = code
    }
    
    public static func databaseClosed(): BadgerException {
        return BadgerException(ErrorCode.DatabaseClosed, "database is closed")
    }
    
    public static func transactionDiscarded(): BadgerException {
        return BadgerException(ErrorCode.TransactionDiscarded, "transaction has been discarded")
    }
    
    public static func transactionCommitted(): BadgerException {
        return BadgerException(ErrorCode.TransactionCommitted, "transaction has already been committed")
    }
    
    public static func readOnlyTransaction(): BadgerException {
        return BadgerException(ErrorCode.ReadOnlyTransaction, "cannot write in read-only transaction")
    }
    
    public static func conflictDetected(): BadgerException {
        return BadgerException(ErrorCode.ConflictDetected, "transaction conflict detected, please retry")
    }
    
    public static func keyNotFound(): BadgerException {
        return BadgerException(ErrorCode.KeyNotFound, "key not found")
    }
    
    public static func ioError(msg: String): BadgerException {
        return BadgerException(ErrorCode.IOError, "IO error: ${msg}")
    }
    
    public static func corruptionError(msg: String): BadgerException {
        return BadgerException(ErrorCode.CorruptionError, "corruption error: ${msg}")
    }
    
    public static func invalidConfig(msg: String): BadgerException {
        return BadgerException(ErrorCode.InvalidConfig, "invalid configuration: ${msg}")
    }
}