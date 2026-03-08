package badgercj.db

import std.collection.ArrayList
import badgercj.table.Meta
import badgercj.table.ValueStruct

/**
 * Iterator - 事务级一致性迭代器
 * 
 * 基于 readTs 提供一致性快照读
 * 
 * 参考：github.com/dgraph-io/badger/v4/iterator.go
 */
public class Iterator {
    private let txn: Transaction
    private let readTs: UInt64
    private let opt: IteratorOptions
    
    private var iitr: MergeIterator
    private var item_: Item
    private var lastKey: Array<Byte>
    private var closed: Bool
    
    public init(txn: Transaction, opt: IteratorOptions) {
        this.txn = txn
        this.readTs = txn.readTs
        this.opt = opt
        this.closed = false
        this.lastKey = []
        
        // 构造迭代器链
        let iters = ArrayList<SimpleIterator>()
        
        // 1. 添加 pending writes 迭代器（如果是 update 事务）
        if (txn.isUpdate()) {
            let writes = txn.getWrites()
            if (!writes.isEmpty()) {
                iters.add(PendingWritesIterator(writes, reverse: opt.reverse))
            }
        }
        
        // 2. 添加 MemTable 迭代器
        let db = txn.getDB()
        let tables = db.getMemTables()
        for (table in tables) {
            iters.add(MemTableIterator(table, reverse: opt.reverse))
        }
        
        // 3. 添加 SSTable 迭代器
        let lc = db.getLevelsController()
        lc.appendIterators(iters, opt)
        
        // 合并迭代器
        this.iitr = MergeIterator(iters, reverse: opt.reverse)
        this.item_ = Item([], [])
    }
    
    public func rewind(): Unit {
        if (closed) {
            return
        }
        lastKey = []
        iitr.rewind()
        parseItem()
    }
    
    public func valid(): Bool {
        if (closed || !iitr.valid()) {
            return false
        }
        
        // 前缀过滤检查
        if (opt.prefix.size > 0) {
            // 当前 key 没有时间戳，直接使用原始 key
            let userKey = item_.key
            if (!hasPrefix(userKey, opt.prefix)) {
                return false
            }
        }
        
        return true
    }
    
    public func next(): Unit {
        if (closed) {
            return
        }
        iitr.next()
        parseItem()
    }
    
    public func item(): Item {
        return item_
    }
    
    public func seek(key: Array<Byte>): Unit {
        if (closed) {
            return
        }
        lastKey = []
        
        var seekKey = key
        if (key.isEmpty() && opt.prefix.size > 0) {
            seekKey = opt.prefix
        }
        
        iitr.seek(seekKey)
        parseItem()
    }
    
    public func close(): Unit {
        if (closed) {
            return
        }
        closed = true
    }
    
    private func parseItem(): Unit {
        while (iitr.valid()) {
            let key = iitr.key()
            let value = iitr.value()
            
            // 当前 key 没有时间戳，直接使用原始 key
            let userKey = key
            
            // 前缀过滤：跳过不匹配前缀的 key
            if (opt.prefix.size > 0 && !hasPrefix(userKey, opt.prefix)) {
                iitr.next()
                continue
            }
            
            // 尝试从 value 解析 ValueStruct 以获取 meta
            let vsOpt = tryDecodeValueStruct(value)
            
            // 检查删除标记
            if (let Some(vs) <- vsOpt) {
                if (vs.isDelete()) {
                    // 跳过已删除的 key
                    if (!opt.allVersions) {
                        lastKey = safeCopy(lastKey, key)
                    }
                    iitr.next()
                    continue
                }
            }
            
            // 非 allVersions 模式：去重（跳过同一 key 的旧版本）
            if (!opt.allVersions && lastKey.size > 0) {
                if (keysEqual(lastKey, key)) {
                    iitr.next()
                    continue
                }
            }
            
            // 更新 lastKey 和 item
            lastKey = safeCopy(lastKey, key)
            
            // 提取实际值和元数据
            var actualValue: Array<Byte> = value
            var version: UInt64 = 0
            var meta: Byte = 0
            
            if (let Some(vs) <- vsOpt) {
                actualValue = vs.value
                version = vs.version
                meta = vs.meta
            }
            
            item_ = Item(
                userKey,
                actualValue,
                version: version,
                meta: meta
            )
            
            // 记录读（用于冲突检测）
            let fp = hashKey(userKey)
            txn.reads.add(fp)
            
            return
        }
        
        // 迭代器无效
        item_ = Item([], [])
    }
    
    private func tryDecodeValueStruct(value: Array<Byte>): ?ValueStruct {
        // ValueStruct 编码格式: [meta:1][userMeta:1][version:varint][expiresAt:8?][valueLen:varint][value...]
        // 最小长度: meta(1) + userMeta(1) + version(1) + valueLen(1) = 4
        if (value.size < 4) {
            return None
        }
        
        try {
            return Some(ValueStruct.decode(value))
        } catch (e: Exception) {
            return None
        }
    }
    
    private func hasPrefix(key: Array<Byte>, prefix: Array<Byte>): Bool {
        if (key.size < prefix.size) {
            return false
        }
        for (i in 0..prefix.size) {
            if (key[i] != prefix[i]) {
                return false
            }
        }
        return true
    }
    
    private func keysEqual(a: Array<Byte>, b: Array<Byte>): Bool {
        if (a.size != b.size) {
            return false
        }
        for (i in 0..a.size) {
            if (a[i] != b[i]) {
                return false
            }
        }
        return true
    }
    
    private func hashKey(key: Array<Byte>): UInt64 {
        var hash: UInt64 = 5381
        for (b in key) {
            hash = ((hash << 5) + hash) + UInt64(b)
        }
        return hash
    }
}
