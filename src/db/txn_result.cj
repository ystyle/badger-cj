package badgercj.db

public enum TxnStatus {
    | Ok
    | Conflict
    | Error(String)
    
    public func isOk(): Bool {
        match (this) {
            case Ok => true
            case Conflict => false
            case Error(_) => false
        }
    }
    
    public func isConflict(): Bool {
        match (this) {
            case Ok => false
            case Conflict => true
            case Error(_) => false
        }
    }
    
    public func isError(): Bool {
        match (this) {
            case Ok => false
            case Conflict => false
            case Error(_) => true
        }
    }
    
    public func getError(): Option<String> {
        match (this) {
            case Ok => None
            case Conflict => None
            case Error(msg) => Some(msg)
        }
    }
}

public enum TxnResult<T> {
    | Success(T)
    | Conflict
    | Error(String)
    
    public func isSuccess(): Bool {
        match (this) {
            case Success(_) => true
            case Conflict => false
            case Error(_) => false
        }
    }
    
    public func isConflict(): Bool {
        match (this) {
            case Success(_) => false
            case Conflict => true
            case Error(_) => false
        }
    }
    
    public func isError(): Bool {
        match (this) {
            case Success(_) => false
            case Conflict => false
            case Error(_) => true
        }
    }
    
    public func getValue(): Option<T> {
        match (this) {
            case Success(v) => Some(v)
            case Conflict => None
            case Error(_) => None
        }
    }
    
    public func getError(): Option<String> {
        match (this) {
            case Success(_) => None
            case Conflict => None
            case Error(msg) => Some(msg)
        }
    }
    
    public func getOrThrow(): T {
        match (this) {
            case Success(v) => v
            case Conflict => throw TxnConflict()
            case Error(msg) => throw Exception(msg)
        }
    }
}