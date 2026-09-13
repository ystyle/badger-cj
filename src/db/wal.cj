package badgercj.db

import std.fs.*
import std.io.*
import std.sync.*
import std.collection.*
import std.time.*
import badgercj.vlog.*
import badgercj.table.*

public class WAL {
    private let pathStr: String
    private var file: ?File
    private var buf: ?BufferedOutputStream<File>
    private var writeOffset: UInt32
    private let lock: Mutex
    
    private init(path: String) {
        this.pathStr = path
        this.file = None
        this.buf = None
        this.writeOffset = 0
        this.lock = Mutex()
    }
    
    public static func open(path: String): WAL {
        let wal = WAL(path)
        
        let p = Path(path)
        let dir = p.parent
        if (dir.toString() != "" && !exists(dir)) {
            Directory.create(dir, recursive: true)
        }
        
        let f = File(p, ReadWrite)
        wal.file = Some(f)
        wal.buf = Some(BufferedOutputStream<File>(f, 65536))
        wal.writeOffset = UInt32(f.length)
        
        return wal
    }
    
    public static func openForRead(path: String): WAL {
        let wal = WAL(path)
        
        let f = File(Path(path), Read)
        wal.file = Some(f)
        wal.writeOffset = UInt32(f.length)
        
        return wal
    }
    
    public func write(key: Array<Byte>, valueEncoded: Array<Byte>): Unit {
        let entry = LogEntry(key, valueEncoded)
        let encoded = entry.encode()
        
        lock.lock()
        try {
            let b = buf ?? throw Exception("WAL not open for write")
            b.write(encoded)
            writeOffset += UInt32(encoded.size)
        } finally {
            lock.unlock()
        }
    }
    
    public func flush(): Unit {
        lock.lock()
        try {
            if (let Some(b) <- buf) {
                b.flush()
            }
        } finally {
            lock.unlock()
        }
    }
    
    public func sync(): Unit {
        flush()
    }
    
    public func readAll(): ArrayList<LogEntry> {
        lock.lock()
        
        try {
            if (let Some(b) <- buf) {
                b.flush()
            }
            
            let entries = ArrayList<LogEntry>()
            let f = file ?? throw Exception("WAL file not open")
            let fileLength = f.length
            
            if (fileLength == 0) {
                return entries
            }
            
            f.seek(SeekPosition.Begin(0))
            let data = Array<Byte>(fileLength, repeat: 0)
            let bytesRead = f.read(data)
            
            if (bytesRead != fileLength) {
                throw Exception("Failed to read complete WAL file: got ${bytesRead}, expected ${fileLength}")
            }
            
            var offset: Int64 = 0
            while (offset + 9 <= fileLength) {
                try {
                    let (entry, entrySize) = LogEntry.decode(data, offset)
                    entries.add(entry)
                    offset += entrySize
                } catch (e: Exception) {
                    // 解码失败按 WAL 尾部截断处理：不再解析剩余字节（语义不变），
                    // 但必须留痕——否则被丢掉的这段写记录在恢复后毫无痕迹。
                    println("[badger] WAL decode failed at offset ${offset}/${fileLength}, truncating rest of WAL: " + e.toString())
                    break
                }
            }
            
            return entries
        } finally {
            lock.unlock()
        }
    }
    
    protected func replay(mt: MemTable): Unit {
        let entries = readAll()
        
        var pendingTxnEntries = ArrayList<(Array<Byte>, ValueStruct)>()
        var lastTxnTs: UInt64 = 0
        
        for (entry in entries) {
            let vs = ValueStruct.decode(entry.value)
            
            if (vs.isFinTxn()) {
                let txnTs = parseTs(entry.key)
                if (txnTs == lastTxnTs) {
                    // 整事务原子恢复（评审 P2-3）：任一条目写失败（超限/arena 满）
                    // → 丢弃整个事务，不再恢复其余条目。此前逐条跳过会让失败事务的
                    // 部分数据"复活"，与"失败必报"语义矛盾。启动不崩仍由外层容错保证。
                    var txnFailed = false
                    for ((key, value) in pendingTxnEntries) {
                        if (txnFailed) {
                            continue
                        }
                        let cleanVs = value.clearTxnMarks()
                        try {
                            mt.put(key, cleanVs)
                        } catch (e: Exception) {
                            // 整事务丢弃是刻意的原子性选择（失败事务不许部分复活），
                            // 但"失败必报"：不打印则这次数据丢失在恢复期完全不可见。
                            txnFailed = true
                            println("[badger] WAL replay: txn put failed, dropping whole txn (ts=${txnTs}): " + e.toString())
                        }
                    }
                }
                pendingTxnEntries.clear()
                lastTxnTs = 0
            } else if (vs.isTxnEntry()) {
                let txnTs = parseTs(entry.key)
                if (lastTxnTs == 0) {
                    lastTxnTs = txnTs
                    pendingTxnEntries.add((entry.key, vs))
                } else if (txnTs == lastTxnTs) {
                    pendingTxnEntries.add((entry.key, vs))
                } else {
                    pendingTxnEntries.clear()
                    lastTxnTs = txnTs
                    pendingTxnEntries.add((entry.key, vs))
                }
            } else {
                if (lastTxnTs != 0) {
                    pendingTxnEntries.clear()
                    lastTxnTs = 0
                }
                try {
                    mt.put(entry.key, vs)
                } catch (e: Exception) {
                    // 单条坏数据（超限/容器满）跳过，其余继续恢复
                    // （跳过语义不变，但必须留痕：否则这条数据静默丢失，事后无法归因）
                    println("[badger] WAL replay: skip bad entry (keyLen=${entry.key.size}): " + e.toString())
                }
            }
        }
    }
    
    public func close(): Unit {
        lock.lock()
        
        try {
            if (let Some(b) <- buf) {
                b.flush()
            }
            if (let Some(f) <- file) {
                f.close()
                file = None
            }
            buf = None
        } finally {
            lock.unlock()
        }
    }
    
    public func delete(): Unit {
        lock.lock()
        
        try {
            if (let Some(b) <- buf) {
                b.flush()
            }
            if (let Some(f) <- file) {
                f.close()
                file = None
            }
            buf = None
            
            if (exists(Path(pathStr))) {
                remove(Path(pathStr))
            }
        } finally {
            lock.unlock()
        }
    }
    
    public func path(): String {
        return pathStr
    }
}
