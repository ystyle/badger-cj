package badgercj.db

import std.fs.*
import std.io.*
import std.sync.*
import std.collection.*
import badgercj.vlog.*
import badgercj.table.*

public class WAL {
    private let pathStr: String
    private var fd: ?File
    private var writeOffset: UInt32
    private let lock: Mutex
    
    private init(path: String) {
        this.pathStr = path
        this.fd = None
        this.writeOffset = 0
        this.lock = Mutex()
    }
    
    public static func open(path: String): WAL {
        let wal = WAL(path)
        
        // 确保目录存在
        let p = Path(path)
        let dir = p.parent
        if (dir.toString() != "" && !exists(dir)) {
            Directory.create(dir, recursive: true)
        }
        
        if (exists(Path(path))) {
            wal.fd = File(Path(path), ReadWrite)
            let file = wal.fd ?? throw Exception("Failed to open WAL file")
            wal.writeOffset = UInt32(file.length)
        } else {
            wal.fd = File(Path(path), ReadWrite)
        }
        
        return wal
    }
    
    public func write(key: Array<Byte>, value: ValueStruct): Unit {
        lock.lock()
        
        try {
            let file = fd ?? throw Exception("WAL file not open")
            
            let entry = LogEntry(key, value.encode())
            
            let encoded = entry.encode()
            file.write(encoded)
            
            writeOffset += UInt32(encoded.size)
        } finally {
            lock.unlock()
        }
    }
    
    public func readAll(): ArrayList<LogEntry> {
        lock.lock()
        
        try {
            let entries = ArrayList<LogEntry>()
            let file = fd ?? throw Exception("WAL file not open")
            
            let fileLength = file.length
            if (fileLength == 0) {
                return entries
            }
            
            file.seek(SeekPosition.Begin(0))
            let data = Array<Byte>(fileLength, repeat: 0)
            let bytesRead = file.read(data)
            
            if (bytesRead != fileLength) {
                throw Exception("Failed to read complete WAL file")
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
    
    public func replay(mt: MemTable): Unit {
        let entries = readAll()
        
        for (entry in entries) {
            let vs = ValueStruct.decode(entry.value)
            mt.put(entry.key, vs)
        }
    }
    
    public func close(): Unit {
        lock.lock()
        
        try {
            if (let Some(file) <- fd) {
                file.close()
                fd = None
            }
        } finally {
            lock.unlock()
        }
    }
    
    public func delete(): Unit {
        lock.lock()
        
        try {
            if (let Some(file) <- fd) {
                file.close()
                fd = None
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
