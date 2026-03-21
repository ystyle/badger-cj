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
    private var writeOffset: UInt32
    private let lock: Mutex
    
    private init(path: String) {
        this.pathStr = path
        this.file = None
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
        
        let f = File(Path(path), ReadWrite)
        wal.file = f
        wal.writeOffset = UInt32(f.length)
        
        return wal
    }
    
    public static func openForRead(path: String): WAL {
        let wal = WAL(path)
        
        let f = File(Path(path), Read)
        wal.file = f
        wal.writeOffset = UInt32(f.length)
        
        return wal
    }
    
    public func write(key: Array<Byte>, value: ValueStruct): Unit {
        if (file.isNone()) {
            return
        }
        let entry = LogEntry(key, value.encode())
        let encoded = entry.encode()
        
        lock.lock()
        try {
            let f = file ?? throw Exception("WAL file not open")
            f.write(encoded)
            writeOffset += UInt32(encoded.size)
        } finally {
            lock.unlock()
        }
    }
    
    public func flush(): Unit {
        lock.lock()
        try {
            if (let Some(f) <- file) {
                f.flush()
            }
        } finally {
            lock.unlock()
        }
    }
    
    public func readAll(): ArrayList<LogEntry> {
        lock.lock()
        
        try {
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
            while (offset < fileLength) {
                let (entry, entrySize) = LogEntry.decode(data, offset)
                entries.add(entry)
                offset += entrySize
            }
            
            return entries
        } finally {
            lock.unlock()
        }
    }
    
    protected func replay(mt: MemTable): Unit {
        let entries = readAll()
        
        for (entry in entries) {
            let vs = ValueStruct.decode(entry.value)
            mt.put(entry.key, vs)
        }
    }
    
    public func close(): Unit {
        lock.lock()
        
        try {
            if (let Some(f) <- file) {
                f.flush()
                f.close()
                file = None
            }
        } finally {
            lock.unlock()
        }
    }
    
    public func delete(): Unit {
        lock.lock()
        
        try {
            if (let Some(f) <- file) {
                f.close()
                file = None
            }
            
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
