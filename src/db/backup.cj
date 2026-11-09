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
    private var maxVersion: UInt64
    private let kvList: ArrayList<StreamKV>
    private var totalSize: Int64
    private let db: Badger
    private let output: OutputStream
    
    public init(db: Badger, output: OutputStream) {
        this.db = db
        this.output = output
        this.maxVersion = 0
        this.kvList = ArrayList<StreamKV>()
        this.totalSize = 0
        writeHeader()
    }
    
    private func writeHeader(): Unit {
        // 直接写输出流：旧实现先攒进 ByteBuffer，finish 才一次性写出，备份多大就驻留多大内存
        output.write(BackupMagicBytes)
        output.write(u32ToLE(BackupVersion))
        output.write(u32ToLE(0u32))
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
        
        // block 头需要总长度：先算精确大小（4 count + 8 maxVersion + 每条 KV 编码长度），
        // 再逐条直接写输出流——不再构造整块 blockData（其峰值 ≈ FlushThreshold）。
        var blockSize: Int64 = 4 + 8
        for (kv in kvList) {
            blockSize += estimateKVSize(kv)
        }
        output.write(u64ToLE(UInt64(blockSize)))
        output.write(u32ToLE(UInt32(kvList.size)))
        output.write(u64ToLE(maxVersion))
        
        for (kv in kvList) {
            writeKV(kv)
        }
        
        kvList.clear()
        totalSize = 0
    }
    
    private func writeKV(kv: StreamKV): Unit {
        let buf = ArrayList<Byte>()
        for (b in u32ToLE(UInt32(kv.key.size))) {
            buf.add(b)
        }
        for (b in kv.key) {
            buf.add(b)
        }
        for (b in u32ToLE(UInt32(kv.value.size))) {
            buf.add(b)
        }
        for (b in kv.value) {
            buf.add(b)
        }
        buf.add(kv.userMeta)
        for (b in u64ToLE(kv.version)) {
            buf.add(b)
        }
        for (b in u64ToLE(kv.expiresAt)) {
            buf.add(b)
        }
        buf.add(kv.meta)
        output.write(buf.toArray())
    }
    
    public func finish(): UInt64 {
        flush()
        output.flush()
        return maxVersion
    }
}

protected class BackupReader {
    private let input: InputStream
    private let db: Badger
    private var entries: ArrayList<Entry>
    private var entriesSize: Int64
    private var totalSize: Int64
    // 流式读取：旧实现把整个备份文件读进 ByteBuffer，备份多大就驻留多大内存
    private let readBuf: Array<Byte>
    private var bufPos: Int64
    private var bufLen: Int64
    
    public init(db: Badger, input: InputStream) {
        this.db = db
        this.input = input
        this.entries = ArrayList<Entry>()
        this.entriesSize = 0
        this.totalSize = 0
        this.readBuf = Array<Byte>(64 * 1024, repeat: 0)
        this.bufPos = 0
        this.bufLen = 0
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
        // 0 字节读取直接返回空数组（tombstone 的 value 就是 0 字节）
        if (n <= 0) {
            return []
        }
        let out = Array<Byte>(n, repeat: 0)
        var copied: Int64 = 0
        while (copied < n) {
            if (bufPos >= bufLen) {
                bufPos = 0
                bufLen = input.read(readBuf)
                if (bufLen <= 0) {
                    break
                }
            }
            let available = bufLen - bufPos
            let want = n - copied
            let take = if (available < want) { available } else { want }
            for (i in 0..take) {
                out[copied + i] = readBuf[bufPos + i]
            }
            bufPos += take
            copied += take
        }
        if (copied == n) { out } else { out[0..copied] }
    }
    
    private func readByte(): Byte {
        let b = readBytes(1)
        if (b.size != 1) {
            throw BadgerException.corruptionError("Unexpected end of backup file")
        }
        b[0]
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
        if (keyLenBuf.size < 4) {
            throw BadgerException.corruptionError("Unexpected end of backup file")
        }
        let keyLen = Int64(u32FromLE(keyLenBuf, 0))
        
        let key = readBytes(keyLen)
        if (key.size != keyLen) {
            throw BadgerException.corruptionError("Unexpected end of backup file")
        }
        
        let valLenBuf = readBytes(4)
        if (valLenBuf.size < 4) {
            throw BadgerException.corruptionError("Unexpected end of backup file")
        }
        let valLen = Int64(u32FromLE(valLenBuf, 0))
        
        let value = readBytes(valLen)
        if (value.size != valLen) {
            throw BadgerException.corruptionError("Unexpected end of backup file")
        }
        
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