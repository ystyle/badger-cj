package badgercj.table

import std.collection.*
import std.fs.*
import std.io.*
import std.sync.*
import badgercj.utils.{compareKeys, keysEqual, hasPrefix}
import snappy.decode

/**
 * Table - SSTable 读取器
 */
protected class Table {
    private let tableData: TableData
    public let id: UInt64
    public let isInMemory: Bool
    private let index: TableIndex
    private let bloomFilter: ?BloomFilter
    // 2.1 Block Cache：可选，容量 0/未配置时为 None（行为与 2.0.1 一致）
    private let blockCache: ?BlockCache
    // 引用计数（起点 1 = 持有者引用）。表不可变，但「从 LevelHandler 摘除」不等于
    // 「没有读者」——迭代器在摘除之后仍要读后续块（compaction 换表期间必然发生）。
    // 迭代器创建时 incrRef、关闭时 decrRef，计数归零才解映射、才删待删文件。
    private let refs: AtomicInt64
    // 待删文件（compaction 换表时标记）：必须等最后一个引用释放后再删，
    // 既避免删掉仍被读的数据，也满足 Windows「先 close 再 unlink」的约束。
    private var deletePath: ?String = None
    private var released: Bool = false
    
    public let smallest: Array<Byte>
    public let biggest: Array<Byte>
    public let keyCount: UInt32
    public let maxVersion: UInt64
    
    public init(id: UInt64, data: Array<Byte>, inMemory!: Bool = false, cache!: ?BlockCache = None) {
        this.id = id
        this.blockCache = cache
        this.refs = AtomicInt64(1)
        // 阶段 A：行为与原实现一致（数据仍常驻内存），仅把存放方式抽到 TableData；
        // 阶段 B 将由 MmapTableData 承接磁盘模式，使表数据离开 GC 堆。
        this.tableData = MemoryTableData(data)
        this.isInMemory = inMemory
        let idx = TableIndex.decodeFromData(data)
        this.index = idx
        if (idx.bloomFilter.size > 0) {
            this.bloomFilter = Some(BloomFilter(idx.bloomFilter))
        } else {
            this.bloomFilter = None
        }
        if (idx.tableSmallest.size > 0) {
            this.smallest = idx.tableSmallest
            this.biggest = idx.tableBiggest
        } else if (idx.blockCount() > 0) {
            this.smallest = idx.keyAt(0)
            this.biggest = idx.keyAt(idx.blockCount() - 1)
        } else {
            this.smallest = []
            this.biggest = []
        }
        this.keyCount = idx.keyCount
        this.maxVersion = idx.maxVersion
    }
    
    /**
     * 以任意 TableData 构造（磁盘模式传 MmapTableData）：索引按需从数据源读取。
     */
    public init(id: UInt64, tableData!: TableData, inMemory!: Bool = false, cache!: ?BlockCache = None) {
        this.id = id
        this.blockCache = cache
        this.refs = AtomicInt64(1)
        this.tableData = tableData
        this.isInMemory = inMemory
        let idx = TableIndex.decodeFromTableData(tableData)
        this.index = idx
        if (idx.bloomFilter.size > 0) {
            this.bloomFilter = Some(BloomFilter(idx.bloomFilter))
        } else {
            this.bloomFilter = None
        }
        if (idx.tableSmallest.size > 0) {
            this.smallest = idx.tableSmallest
            this.biggest = idx.tableBiggest
        } else if (idx.blockCount() > 0) {
            this.smallest = idx.keyAt(0)
            this.biggest = idx.keyAt(idx.blockCount() - 1)
        } else {
            this.smallest = []
            this.biggest = []
        }
        this.keyCount = idx.keyCount
        this.maxVersion = idx.maxVersion
    }
    
    public func get(key: Array<Byte>): Option<Array<Byte>> {
        if (!mayContain(key)) {
            return None
        }
        
        let idx = findBlock(key)
        if (idx < 0) {
            return None
        }
        
        let block = readBlock(idx)
        let iter = BlockIterator(block, index.keyAt(idx))
        iter.seek(key)
        
        if (iter.isValid() && keysEqual(iter.key(), key)) {
            return Some(iter.value())
        }
        return None
    }
    
    /** 表数据字节数（on-disk 大小：映射/内存模式一致）。 */
    public func dataSize(): Int64 {
        tableData.size()
    }
    
    /** 表数据是否由只读映射承载（false = 常驻 GC 堆的 Array<Byte>）。 */
    public func isMmapBacked(): Bool {
        tableData is MmapTableData
    }
    
    public func mayContain(key: Array<Byte>): Bool {
        match (bloomFilter) {
            case Some(bf) => bf.mayContain(key)
            case None => true
        }
    }
    
    public func hasBloomFilter(): Bool {
        bloomFilter.isSome()
    }
    
    public func bloomFilterSize(): Int64 {
        match (bloomFilter) {
            case Some(bf) => bf.size()
            case None => 0
        }
    }
    
    public func newIterator(): TableIter {
        // 迭代器持有表引用：即便该表随后被 compaction 摘除，迭代器仍能读完自己那份数据
        incrRef()
        return TableIterator(this)
    }
    
    public func numBlocks(): Int64 {
        return index.blockCount()
    }
    
    /** 索引本体堆占用（诊断/测试：raw + 4B/块，不含数据块与 bloom）。 */
    public func indexHeapBytes(): Int64 {
        return index.heapBytes()
    }
    
    public func blockIterator(idx: Int64): BlockIterator {
        let block = readBlock(idx)
        return BlockIterator(block, index.keyAt(idx))
    }
    
    private func readBlock(idx: Int64): Array<Byte> {
        // 命中缓存直接返回；未命中读盘后塞入（容量 0 时不缓存）
        if (let Some(c) <- blockCache) {
            if (let Some(hit) <- c.get(id, idx)) {
                return hit
            }
        }
        let data = readBlockUncached(idx)
        if (let Some(c) <- blockCache) {
            c.put(id, idx, data)
        }
        return data
    }
    
    private func readBlockUncached(idx: Int64): Array<Byte> {
        let blockData = tableData.read(Int64(index.offsetAt(idx)), Int64(index.lenAt(idx)))
        
        // 解压 Block
        if (index.compressionAt(idx) == CompressionType.Snappy) {
            return decompressBlock(blockData)
        }
        return blockData
    }
    
    private func decompressBlock(compressed: Array<Byte>): Array<Byte> {
        let dst = Array<Byte>(compressed.size * 4, repeat: 0)  // 预估解压后大小
        decode(dst, compressed)
    }
    
    public func findBlock(key: Array<Byte>): Int64 {
        if (index.blockCount() == 0) {
            return -1
        }
        
        let left = index.findBlockPos(key)
        
        let cmp = index.compareKeyWithBlock(left, key)
        if (cmp >= 0 || left == 0) {
            return left
        }
        
        // R3 修复：key < 块首 且与块首同属一个 user key（块首即该组首条 = 最大版本）。
        // 此时 key 是「readTs ≥ 组内最大存储版本」的 seek（keyWithTs 编码 ts 取反降序，
        // 更大 ts 排更前）——key 实际仍落在该块的 user key 组内（组首条 ≤ readTs 可命中），
        // 必须返回本块而非回退前一块（回退会在前一块内 seek 到块尾而稳定 miss）。
        if (sameUserKey(key, index.keyAt(left))) {
            return left
        }
        
        return left - 1
    }
    
    // 比较两个带 ts 的存储 key 是否同属一个 user key（去掉尾部 8 字节 ts 后相等）
    private func sameUserKey(a: Array<Byte>, b: Array<Byte>): Bool {
        if (a.size <= 8 || b.size <= 8) {
            return false
        }
        let alen = a.size - 8
        let blen = b.size - 8
        if (alen != blen) {
            return false
        }
        for (i in 0..alen) {
            if (a[i] != b[i]) {
                return false
            }
        }
        true
    }
    
    /**
     * 新增一个引用（迭代器等读者调用）。持有者提交引用后调用未配对的 decrRef 即可。
     */
    public func incrRef(): Unit {
        refs.fetchAdd(1)
    }

    /**
     * 释放一个引用。归零时才解除底层数据源（磁盘模式解除映射）并删除待删文件。
     *
     * 为什么必须按引用释放：从 LevelHandler 摘除只保证「没有新的读者能拿到这张表」，
     * 已经在读的迭代器还要继续读它的后续块。若摘除即解映射，迭代器下一次进块就撞上
     * 已关闭的映射（`MmapFile is closed`）。读块是复制语义，所以延迟到最后一个引用
     * 释放是安全且充分的。
     *
     * 幂等：重复释放不会把计数打成负数（检测到已归零即恢复原值）。
     */
    public func decrRef(): Unit {
        let old = refs.fetchSub(1)
        if (old <= 0) {
            refs.fetchAdd(1)
            return
        }
        if (old == 1) {
            shutdown()
        }
    }

    /** 释放持有者引用（历史接口名，等价 decrRef）。 */
    public func close(): Unit {
        decrRef()
    }

    /**
     * 强制释放（数据库关闭用）：忽略尚未归还的读者引用。
     * 只在确认进程内不再读这张表时使用（Badger.close 的路径）。
     */
    public func closeForce(): Unit {
        refs.store(0)
        shutdown()
    }

    /** 标记表文件在最后一个引用释放时删除（compaction 换表时调用）。 */
    public func markForDeletion(path: String): Unit {
        deletePath = Some(path)
    }

    /** 当前引用计数（诊断/测试用）。 */
    public func refCount(): Int64 {
        refs.load()
    }

    /** 真正释放底层资源：失效缓存条目 → 解映射 → 删待删文件。只执行一次。 */
    private func shutdown(): Unit {
        if (released) {
            return
        }
        released = true
        // 摘表先失效该表的缓存条目：compaction 替换后同 blockIdx 可能是另一份内容
        if (let Some(c) <- blockCache) {
            c.invalidateTable(id)
        }
        tableData.close()
        if (let Some(p) <- deletePath) {
            // 删除失败不阻断：MANIFEST 已移除该表，文件最迟由 open 时的孤儿清理回收
            try {
                if (exists(Path(p))) {
                    remove(Path(p))
                }
            } catch (e: Exception) {
                // 忽略：文件可能仍被别的句柄占用
            }
        }
    }
    
    public func onDiskSize(): Int64 {
        tableData.size()
    }
    
    public func uncompressedSize(): Int64 {
        tableData.size()
    }
    
    public func offsetsLength(): Int64 {
        index.blockCount()
    }
    
    public func getOffsetKey(idx: Int64): Array<Byte> {
        if (idx < 0 || idx >= index.blockCount()) {
            return []
        }
        index.keyAt(idx)
    }
    
    public func keySplits(n: Int64, prefix: Array<Byte>): ArrayList<Array<Byte>> {
        let result = ArrayList<Array<Byte>>()
        if (n <= 0) {
            return result
        }
        
        let oLen = index.blockCount()
        var jump = oLen / n
        if (jump == 0) {
            jump = 1
        }
        
        var i: Int64 = 0
        while (i < oLen) {
            let key = getOffsetKey(i)
            if (hasPrefix(key, prefix)) {
                result.add(key)
            }
            i += jump
        }
        
        result
    }
}