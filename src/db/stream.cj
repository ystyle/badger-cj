package badgercj.db

import std.collection.*
import std.sync.*
import badgercj.utils.compareKeys

/**
 * StreamKV - 流式 API 的 KV 结构
 */
public struct StreamKV {
    public let key: Array<Byte>
    public let value: Array<Byte>
    public let userMeta: Byte
    public let version: UInt64
    public let expiresAt: UInt64
    public let meta: Byte
    
    public init(
        key!: Array<Byte>,
        value!: Array<Byte>,
        userMeta!: Byte = 0,
        version!: UInt64 = 0,
        expiresAt!: UInt64 = 0,
        meta!: Byte = 0
    ) {
        this.key = key
        this.value = value
        this.userMeta = userMeta
        this.version = version
        this.expiresAt = expiresAt
        this.meta = meta
    }
}

/**
 * Stream - 并发迭代框架
 * 
 * 用于批量处理数据库中的 key-value 对
 */
public class Stream {
    private let db: Badger
    
    public var prefix: Array<Byte>
    public var numSpawn: Int64
    public var sinceTs: UInt64
    public var chooseKey: ?(Item) -> Bool
    public var keyToList: ?(Array<Byte>, Iterator) -> ArrayList<StreamKV>
    public var send: ?(ArrayList<StreamKV>) -> Unit
    
    public init(db: Badger) {
        this.db = db
        this.prefix = []
        this.numSpawn = 8
        this.sinceTs = 0
        this.chooseKey = None
        this.keyToList = None
        this.send = None
    }
    
    /**
     * Orchestrate - 执行流式处理
     */
    public func orchestrate(): Unit {
        let readTs = db.oracle.readTs()
        
        let rangeChan = NotifyingWriteChannel<KeyRange>(100)
        let kvChan = NotifyingWriteChannel<ArrayList<StreamKV>>(100)
        let counter = AtomicInt64(0)
        
        produceRanges(rangeChan)
        
        for (threadId in 0..numSpawn) {
            let tid = threadId
            spawn {
                produceKVs(rangeChan, readTs, kvChan, tid)
                let done = counter.fetchAdd(1) + 1
                if (done == numSpawn) {
                    kvChan.close()
                }
            }
        }
        
        streamKVs(kvChan)
    }
    
    private func produceRanges(rangeChan: NotifyingWriteChannel<KeyRange>): Unit {
        let ranges = db.ranges(prefix, numSpawn)
        
        if (ranges.isEmpty()) {
            if (prefix.size > 0) {
                rangeChan.add(KeyRange([], prefix, false))
            } else {
                rangeChan.add(KeyRange([], [], false))
            }
        } else {
            for (r in ranges) {
                rangeChan.add(r)
            }
        }
        
        rangeChan.close()
    }
    
    // readTs: 读取时间戳（当前使用 txn 内部时间戳，保留用于未来扩展）
    // threadId: 线程 ID（当前实现未使用，保留用于调试日志）
    private func produceKVs(
        rangeChan: NotifyingWriteChannel<KeyRange>,
        _: UInt64,
        kvChan: NotifyingWriteChannel<ArrayList<StreamKV>>,
        _: Int64
    ): Unit {
        let txn = db.newTransaction(update: false)
        try {
            let iterOpts = IteratorOptions(
                allVersions: true,
                prefix: prefix,
                prefetchValues: true,
                sinceTs: sinceTs
            )
            let iter = txn.newIterator(opt: iterOpts)
            try {
                while (true) {
                    match (rangeChan.remove()) {
                        case Some(range) =>
                            iterateRange(range, iter, kvChan)
                        case None =>
                            break
                    }
                }
            } finally {
                iter.close()
            }
        } finally {
            txn.discard()
        }
    }
    
    private func iterateRange(
        range: KeyRange,
        iter: Iterator,
        kvChan: NotifyingWriteChannel<ArrayList<StreamKV>>
    ): Unit {
        iter.seek(range.left)
        
        let batchSize: Int64 = 16 * 1024 * 1024
        var currentSize: Int64 = 0
        var batch = ArrayList<StreamKV>()
        
        while (iter.valid()) {
            let item = iter.item()
            let key = item.keyCopy()
            
            if (range.hasRight && compareKeys(key, range.right) >= 0) {
                break
            }
            
            if (let Some(choose) <- chooseKey) {
                if (!choose(item)) {
                    iter.next()
                    continue
                }
            }
            
            let list = toList(key, iter)
            
            for (kv in list) {
                batch.add(kv)
                currentSize += kv.key.size + kv.value.size
            }
            
            if (currentSize >= batchSize && batch.size > 0) {
                kvChan.add(batch)
                batch = ArrayList<StreamKV>()
                currentSize = 0
            }
        }
        
        if (batch.size > 0) {
            kvChan.add(batch)
        }
    }
    
    private func toList(key: Array<Byte>, iter: Iterator): ArrayList<StreamKV> {
        if (let Some(fn) <- keyToList) {
            return fn(key, iter)
        }
        defaultToList(key, iter)
    }
    
    private func defaultToList(key: Array<Byte>, iter: Iterator): ArrayList<StreamKV> {
        let list = ArrayList<StreamKV>()
        
        while (iter.valid()) {
            let item = iter.item()
            
            if (item.isDeletedOrExpired()) {
                break
            }
            
            if (compareKeys(item.keyCopy(), key) != 0) {
                break
            }
            
            let value = item.valueCopy()
            let kv = StreamKV(
                key: key,
                value: value,
                userMeta: item.userMeta,
                version: item.version,
                expiresAt: item.expiresAt
            )
            list.add(kv)
            
            iter.next()
        }
        
        list
    }
    
    private func streamKVs(kvChan: NotifyingWriteChannel<ArrayList<StreamKV>>): Unit {
        while (true) {
            match (kvChan.remove()) {
                case Some(batch) =>
                    if (let Some(fn) <- send) {
                        fn(batch)
                    }
                case None =>
                    break
            }
        }
    }
}

/**
 * KeyRange - key 范围 [left, right)
 */
protected class KeyRange {
    public let left: Array<Byte>
    public var right: Array<Byte>
    public var hasRight: Bool
    public var size: Int64
    
    public init(left: Array<Byte>, right: Array<Byte>, hasRight: Bool) {
        this.left = left
        this.right = right
        this.hasRight = hasRight
        this.size = 0
    }
}