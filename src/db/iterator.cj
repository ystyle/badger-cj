package badgercj.db

import std.collection.ArrayList
import badgercj.table.Meta
import badgercj.table.ValueStruct
import badgercj.utils.{hasPrefix, hashKey, keysEqual}

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
    // 反向模式：collectReverseLatest 消费完当前 userKey 版本链后，iitr 已定位到
    // 下一个 userKey 的首个条目；next() 不能再 advance，否则会跳过该 key。
    private var skipAdvance: Bool
    // parseItem 是否产出了有效 item。valid() 不能只看 iitr.valid()：
    // collectReverseLatest 消费到表内最后一段版本链（无后续 userKey 垫底，如磁盘表
    // 末尾 key 之后无 finTxn 标记）时 iitr 已越界 invalid，但 item_ 仍然有效——
    // 若以 iitr 状态判定会把最后一项吞掉（memtable 因 finTxn 垫底 key 掩盖此问题）。
    private var itemValid: Bool
    
    public init(txn: Transaction, opt: IteratorOptions) {
        this.txn = txn
        this.readTs = txn.readTs
        this.opt = opt
        this.closed = false
        this.lastKey = []
        this.skipAdvance = false
        this.itemValid = false
        
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
        // VLog GC 延迟删除依赖活跃迭代器计数（旧段的值指针可能被本迭代器读到）
        db.incrIteratorCount()
    }
    
    public func rewind(): Unit {
        if (closed) {
            return
        }
        lastKey = []
        skipAdvance = false
        iitr.rewind()
        parseItem()
    }
    
    public func valid(): Bool {
        // 不能只看 iitr.valid()：collectReverseLatest 消费完表内最后一段版本链
        // （无后续 userKey 垫底）时 iitr 已越界 invalid，但 item_ 有效——以
        // itemValid（parseItem 产出状态）为准，最后一项不被吞。
        if (closed || !itemValid) {
            return false
        }
        
        if (opt.prefix.size > 0) {
            if (!hasPrefix(item_.key, opt.prefix)) {
                return false
            }
        }
        
        return true
    }
    
    public func validForPrefix(prefix: Array<Byte>): Bool {
        valid() && hasPrefix(item_.key, prefix)
    }
    
    public func next(): Unit {
        if (closed) {
            return
        }
        if (skipAdvance) {
            // collectReverseLatest 已消费当前 userKey 版本链，iitr 已位于下一 key 首条目
            skipAdvance = false
        } else {
            iitr.next()
        }
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
        skipAdvance = false
        
        var seekKey = key
        if (key.isEmpty() && opt.prefix.size > 0) {
            seekKey = opt.prefix
        }
        
        // 为 seek key 编码版本后缀（对齐 badger-go Iterator.Seek）：
        // - forward：ts=MaxUint64 → 反转后后缀 0x00..00（组内最小），findGe ≥ seekKey
        //   命中该 user key 组首条（最新版本），ts>readTs 的版本由 parseItem 过滤
        // - reverse：ts=0 → 反转后后缀 0xFF..FF（组内最大），"≤ seekKey 的最后一条"
        //   二分可覆盖目标 user key 组全部条目 → 定位组内末条（最旧版本），
        //   collectReverseLatest 自旧至新收集整组后输出最新可见版本。
        //   此前 reverse 也统一用 ts=MaxUint64（后缀 0x00..00）：目标组条目全部
        //   > seekKey，二分落到前一组/空——seek 到表内存在的 key 漏掉该 key 自身
        //   （seek key1 → []、key2 → [key1]，而 badger-go Seek 到存在 key 应含自身）。
        if (seekKey.size > 0) {
            if (opt.reverse) {
                seekKey = keyWithTs(seekKey, 0u64)
            } else {
                seekKey = keyWithTs(seekKey, 0xFFFFFFFFFFFFFFFFu64)
            }
        }
        
        iitr.seek(seekKey)
        parseItem()
    }
    
    public func close(): Unit {
        if (closed) {
            return
        }
        closed = true
        // 关闭子迭代器：归还它们持有的表引用（被 compaction 摘除的表由最后一个引用
        // 负责解映射 + 删文件）；最后一个迭代器关闭时 VLog GC 挂起的旧段才会删除
        iitr.close()
        txn.getDB().decrIteratorCount()
    }
    
    private func parseItem(): Unit {
        while (iitr.valid()) {
            let key = iitr.key()
            let value = iitr.value()
            
            // 解析时间戳
            let ts = parseTs(key)
            
            // 版本过滤：跳过超过 readTs 的版本
            if (ts > readTs && ts != 0) {
                iitr.next()
                continue
            }
            
            // 解析用户 key（去掉时间戳）
            let userKey = parseKey(key)
            
            // 前缀过滤：跳过不匹配前缀的 key
            if (opt.prefix.size > 0 && !hasPrefix(userKey, opt.prefix)) {
                iitr.next()
                continue
            }
            
            if (opt.reverse && !opt.allVersions) {
                // 反向模式：key 编码为 [userKey][反转ts]，同 userKey 的版本按「旧→新」到达。
                // 必须收集整条版本链取最新有效版本，否则会把旧版本当最新返回；
                // 最新版本为删除/过期时整 key 跳过（见 ReverseVersionTest）。
                if (collectReverseLatest(userKey)) {
                    itemValid = true
                    return
                }
                continue
            }
            
            // 尝试从 value 解析 ValueStruct 以获取 meta
            let vsOpt = tryDecodeValueStruct(value)
            
            // 跳过事务结束标记（bitFinTxn）
            if (let Some(vs) <- vsOpt) {
                if (vs.isFinTxn()) {
                    iitr.next()
                    continue
                }
            }
            
            // 检查删除或过期：默认模式跳过（tombstone 不对外可见）；allVersions 模式继续产出——
            // 否则调用方无法区分「key 不存在」与「已删除」，且 Backup/Stream 会漏掉删除标记
            //（恢复后旧值复活）。go badger 的 iterator 同样在 AllVersions 下返回 tombstone。
            if (let Some(vs) <- vsOpt) {
                if (isDeletedOrExpired(vs.meta, vs.expiresAt) && !opt.allVersions) {
                    lastKey = safeCopy(lastKey, key)
                    iitr.next()
                    continue
                }
            }
            
            // 非 allVersions 模式：去重（跳过同一 key 的旧版本）
            if (!opt.allVersions && lastKey.size > 0) {
                if (sameKey(lastKey, key)) {
                    iitr.next()
                    continue
                }
            }
            
            // 更新 lastKey 和 item
            lastKey = safeCopy(lastKey, key)
            
            // 提取实际值和元数据
            var actualValue: Array<Byte> = value
            var version: UInt64 = ts
            var meta: Byte = 0
            var userMeta: Byte = 0
            var expiresAt: UInt64 = 0
            
            if (let Some(vs) <- vsOpt) {
                actualValue = vs.value
                version = vs.version
                meta = vs.meta
                userMeta = vs.userMeta
                expiresAt = vs.expiresAt
            }
            
            item_ = Item(
                userKey,
                actualValue,
                version: version,
                meta: meta,
                userMeta: userMeta,
                expiresAt: expiresAt
            )
            itemValid = true
            
            // 记录读（用于冲突检测）
            let fp = hashKey(userKey)
            txn.reads.add(fp)
            
            return
        }
        
        // 迭代器无效
        item_ = Item([], [])
        itemValid = false
    }
    
    // 反向模式收集：消费当前 userKey 的全部可见版本（物理连续），
    // 输出最新有效版本（ts 最大且未删除/未过期）；整链无有效版本则跳过。
    // 反向顺序旧→新：候选随遍历更新，遇到删除/过期版本清空候选（覆盖旧版本）。
    private func collectReverseLatest(userKey: Array<Byte>): Bool {
        var latestKey: Array<Byte> = []
        var latestValue: Array<Byte> = []
        var latestTs: UInt64 = 0
        var latestMeta: Byte = 0
        var latestUserMeta: Byte = 0
        var latestExpiresAt: UInt64 = 0
        var found: Bool = false
        while (iitr.valid()) {
            let k = iitr.key()
            if (!keysEqual(parseKey(k), userKey)) {
                break   // 已到下一个 userKey
            }
            let v = iitr.value()
            let t = parseTs(k)
            if (t > readTs && t != 0) {
                iitr.next()
                continue
            }
            if (let Some(vs) <- tryDecodeValueStruct(v)) {
                if (vs.isFinTxn()) {
                    iitr.next()
                    continue
                }
                if (isDeletedOrExpired(vs.meta, vs.expiresAt)) {
                    // 删除/过期版本（更新的版本）：清空候选，旧版本全部无效
                    found = false
                } else {
                    latestKey = safeCopy(latestKey, k)
                    latestValue = safeCopy(latestValue, vs.value)
                    latestTs = vs.version
                    latestMeta = vs.meta
                    latestUserMeta = vs.userMeta
                    latestExpiresAt = vs.expiresAt
                    found = true
                }
            } else {
                // 无法解码 ValueStruct：视为普通值
                latestKey = safeCopy(latestKey, k)
                latestValue = safeCopy(latestValue, v)
                latestTs = t
                latestMeta = 0
                latestUserMeta = 0
                latestExpiresAt = 0
                found = true
            }
            iitr.next()
        }
        if (!found) {
            return false
        }
        // 记录读（用于冲突检测）
        let fp = hashKey(userKey)
        txn.reads.add(fp)
        item_ = Item(
            parseKey(latestKey),
            latestValue,
            version: latestTs,
            meta: latestMeta,
            userMeta: latestUserMeta,
            expiresAt: latestExpiresAt
        )
        lastKey = safeCopy(lastKey, latestKey)
        // iitr 已消费完当前 userKey 的全部版本，位于下一 key 首条目（或已无效），
        // next() 无需再 advance，否则会跳过下一个 key（见 skipAdvance 注释）。
        skipAdvance = true
        true
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
}
