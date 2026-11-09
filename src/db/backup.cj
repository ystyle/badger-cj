package badgercj.db

import std.collection.*
import std.io.*
import std.fs.*
import std.binary.*
import badgercj.utils.{compareKeys, u32ToLE, u32FromLE, u64ToLE, u64FromLE}
import badgercj.table.Meta

private let BackupMagicBytes: Array<Byte> = [66, 65, 68, 67, 74]
private let BackupVersion: UInt32 = 1u32
private let FlushThreshold: Int64 = 100 << 20
private let MaxBatchCount: Int64 = 1000
private let MaxBatchSize: Int64 = 16 << 20

protected class BackupWriter {
    private let writer: ByteBuffer
    private var maxVersion: UInt64
    private let kvList: ArrayList<StreamKV>
    private var totalSize: Int64
    private let db: Badger
    private let output: OutputStream
    
    public init(db: Badger, output: OutputStream) {
        this.db = db
        this.writer = ByteBuffer()
        this.output = output
        this.maxVersion = 0
        this.kvList = ArrayList<StreamKV>()
        this.totalSize = 0
        writeHeader()
    }
    
    private func writeHeader(): Unit {
        for (b in BackupMagicBytes) {
            writer.writeByte(b)
        }
        let versionBuf = u32ToLE(BackupVersion)
        writer.write(versionBuf)
        let flagsBuf = u32ToLE(0u32)
        writer.write(flagsBuf)
    }
    
    public func addKV(kv: StreamKV): Unit {
        if (kv.version > maxVersion) {
            maxVersion = kv.version
        }
        
        let kvSize = estimateKVSize(kv)
        
        if (totalSize + kvSize >= FlushThreshold) {
            flush()
        }
        
        kvList.add(kv)
        totalSize += kvSize
    }
    
    private func estimateKVSize(kv: StreamKV): Int64 {
        return 4 + kv.key.size + 4 + kv.value.size + 1 + 8 + 8 + 1
    }
    
    public func flush(): Unit {
        if (kvList.isEmpty()) {
            return
        }
        
        let blockData = ArrayList<Byte>()
        let count = UInt32(kvList.size)
        let countBuf = u32ToLE(count)
        for (b in countBuf) {
            blockData.add(b)
        }
        
        let maxVerBuf = u64ToLE(maxVersion)
        for (b in maxVerBuf) {
            blockData.add(b)
        }
        
        for (kv in kvList) {
            writeKVToBuffer(blockData, kv)
        }
        
        let sizeBuf = u64ToLE(UInt64(blockData.size))
        writer.write(sizeBuf)
        
        for (b in blockData) {
            writer.writeByte(b)
        }
        
        kvList.clear()
        totalSize = 0
    }
    
    private func writeKVToBuffer(buf: ArrayList<Byte>, kv: StreamKV): Unit {
        let keyLenBuf = u32ToLE(UInt32(kv.key.size))
        for (b in keyLenBuf) {
            buf.add(b)
        }
        for (b in kv.key) {
            buf.add(b)
        }
        
        let valLenBuf = u32ToLE(UInt32(kv.value.size))
        for (b in valLenBuf) {
            buf.add(b)
        }
        for (b in kv.value) {
            buf.add(b)
        }
        
        buf.add(kv.userMeta)
        
        let verBuf = u64ToLE(kv.version)
        for (b in verBuf) {
            buf.add(b)
        }
        
        let expBuf = u64ToLE(kv.expiresAt)
        for (b in expBuf) {
            buf.add(b)
        }
        
        buf.add(kv.meta)
    }
    
    public func finish(): UInt64 {
        flush()
        output.write(writer.bytes())
        output.flush()
        return maxVersion
    }
}

protected class BackupReader {
    private let reader: ByteBuffer
    private let db: Badger
    private var entries: ArrayList<Entry>
    private var entriesSize: Int64
    private var totalSize: Int64
    
    public init(db: Badger, input: InputStream) {
        this.db = db
        this.reader = ByteBuffer()
        let buf = ArrayList<Byte>()
        var tmp = Array<Byte>(4096, repeat: 0)
        while (true) {
            let n = input.read(tmp)
            if (n <= 0) {
                break
            }
            for (i in 0..n) {
                buf.add(tmp[i])
            }
        }
        reader.write(buf.toArray())
        this.entries = ArrayList<Entry>()
        this.entriesSize = 0
        this.totalSize = 0
        readHeader()
    }
    
    private func readHeader(): Unit {
        let magic = readBytes(5)
        
        for (i in 0..5) {
            if (magic[i] != BackupMagicBytes[i]) {
                throw BadgerException.corruptionError("Invalid backup file: magic mismatch")
            }
        }
        
        let versionBuf = readBytes(4)
        let version = u32FromLE(versionBuf, 0)
        
        if (version > BackupVersion) {
            throw BadgerException.corruptionError("Unsupported backup version: ${version}")
        }
        
        let _ = readBytes(4)
    }
    
    private func readBytes(n: Int64): Array<Byte> {
        // 长度为 0 时不能调用 ByteBuffer.read：目标数组为空会抛
        // IllegalArgumentException("The buffer is empty")——tombstone 的 value 就是 0 字节。
        if (n <= 0) {
            return []
        }
        let buf = Array<Byte>(n, repeat: 0)
        reader.read(buf)
        buf
    }
    
    private func readByte(): Byte {
        match (reader.readByte()) {
            case Some(b) => b
            case None => throw BadgerException.corruptionError("Unexpected end of backup file")
        }
    }
    
    public func restore(): Unit {
        while (true) {
            let sizeBuf = readBytes(8)
            if (sizeBuf.size < 8) {
                break
            }
            
            let blockSize = u64FromLE(sizeBuf, 0)
            
            if (blockSize == 0) {
                break
            }
            
            readBlock(blockSize)
        }
        
        flushEntries()
        
        db.doneRestore()
    }
    
    // blockSize: block 大小（当前未使用，保留用于未来验证）
    private func readBlock(_: UInt64): Unit {
        let countBuf = readBytes(4)
        if (countBuf.size < 4) {
            throw BadgerException.corruptionError("Unexpected end of backup file")
        }
        let count = u32FromLE(countBuf, 0)
        
        let maxVerBuf = readBytes(8)
        if (maxVerBuf.size < 8) {
            throw BadgerException.corruptionError("Unexpected end of backup file")
        }
        let maxVersion = u64FromLE(maxVerBuf, 0)
        
        db.updateNextTs(maxVersion)
        
        for (_ in 0..Int64(count)) {
            let kv = readKV()
            addEntry(kv)
        }
    }
    
    private func readKV(): StreamKV {
        let keyLenBuf = readBytes(4)
        let keyLen = Int64(u32FromLE(keyLenBuf, 0))
        
        let key = readBytes(keyLen)
        
        let valLenBuf = readBytes(4)
        let valLen = Int64(u32FromLE(valLenBuf, 0))
        
        let value = readBytes(valLen)
        
        let userMeta = readByte()
        
        let verBuf = readBytes(8)
        let version = u64FromLE(verBuf, 0)
        
        let expBuf = readBytes(8)
        let expiresAt = u64FromLE(expBuf, 0)
        
        let meta = readByte()
        
        return StreamKV(
            key: key,
            value: value,
            userMeta: userMeta,
            version: version,
            expiresAt: expiresAt,
            meta: meta
        )
    }
    
    private func addEntry(kv: StreamKV): Unit {
        let isDelete = (kv.meta & Meta.bitDelete) != 0
        if (isDelete) {
            db.setRaw(kv.key, [], kv.meta, kv.version, kv.expiresAt)
        } else {
            db.setRaw(kv.key, kv.value, kv.meta, kv.version, kv.expiresAt)
        }
        db.updateNextTs(kv.version)
    }
    
    private func flushEntries(): Unit {
    }
}