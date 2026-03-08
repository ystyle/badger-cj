# BadgerDB 核心算法深度解析

本文档详细分析 BadgerDB 的核心算法实现，为仓颉移植提供算法层面的参考。

## 1. Skiplist 并发跳表算法

### 1.1 基本概念

Skiplist 是一种概率数据结构，用于替代平衡树，提供 O(log n) 的查找、插入和删除性能。

**特点：**
- 基于"跳跃"思想，多层索引结构
- 并发友好，无需复杂的树旋转
- 实现简单，性能优秀

### 1.2 数据结构

```go
// Node 结构（Go 实现）
type node struct {
    // Value 编码为单个 uint64 (原子操作)
    // 高 32 位: value size
    // 低 32 位: value offset
    value atomic.Uint64
    
    keyOffset uint32  // Key 在 Arena 中的偏移量
    keySize   uint16  // Key 长度
    height    uint16  // 节点高度（塔层数）
    
    // Tower 数组：每层的下一个节点指针
    tower [maxHeight]atomic.Uint32
}

// Skiplist 结构
type Skiplist struct {
    height atomic.Int32  // 当前最大高度 (1 <= height <= 20)
    head   *node         // 头节点（哨兵）
    ref    atomic.Int32  // 引用计数
    arena  *Arena        // 内存池
}
```

**关键点：**
- 所有指针使用 Arena 偏移量（uint32）代替
- 使用 `atomic` 操作保证并发安全
- `maxHeight = 20`（经验值，支持 2^20 个元素）

### 1.3 概率性高度生成

```go
const (
    maxHeight      = 20
    heightIncrease = math.MaxUint32 / 3  // ~1.4 billion
)

func randomHeight() int {
    h := 1
    for h < maxHeight && z.FastRand() <= heightIncrease {
        h++
    }
    return h
}
```

**算法分析：**
- 概率 p = 1/3 的几何分布
- 期望高度：E[h] = 1/(1-p) ≈ 1.5
- 高度分布：
  - Level 0: 100% 的节点
  - Level 1: ~33% 的节点
  - Level 2: ~11% 的节点
  - Level k: ~(1/3)^k 的节点

**仓颉实现建议：**
```cangjie
func randomHeight(): Int {
    var h = 1
    while (h < MAX_HEIGHT && fastRand() <= HEIGHT_INCREASE) {
        h++
    }
    return h
}

// FastRand 性能优化（无锁随机数）
func fastRand(): UInt32 {
    // 使用简单的线性同余生成器
    // 或调用系统随机数 API
}
```

### 1.4 查找算法（findNear）

```go
// findNear 查找最接近 key 的节点
// less=true: 找右边界（node.key < key 或 node.key <= key）
// less=false: 找左边界（node.key > key 或 node.key >= key）
func (s *Skiplist) findNear(key []byte, less bool, allowEqual bool) (*node, bool) {
    x := s.head
    level := int(s.getHeight() - 1)
    
    for {
        next := s.getNext(x, level)
        
        if next == nil {
            // 到达列表末尾
            if level > 0 {
                level--  // 下降一层
                continue
            }
            // 已经在底层
            if !less {
                return nil, false
            }
            if x == s.head {
                return nil, false
            }
            return x, false
        }
        
        nextKey := next.key(s.arena)
        cmp := y.CompareKeys(key, nextKey)
        
        if cmp > 0 {
            // x.key < next.key < key，继续向右
            x = next
            continue
        }
        
        if cmp == 0 {
            // 找到相等节点
            if allowEqual {
                return next, true
            }
            if !less {
                return s.getNext(next, 0), false
            }
            if level > 0 {
                level--
                continue
            }
            if x == s.head {
                return nil, false
            }
            return x, false
        }
        
        // cmp < 0: x.key < key < next.key
        if level > 0 {
            level--
            continue
        }
        
        // 底层
        if !less {
            return next, false
        }
        if x == s.head {
            return nil, false
        }
        return x, false
    }
}
```

**算法复杂度：**
- 时间复杂度：O(log n) 期望，O(n) 最坏
- 空间复杂度：O(1)
- 并发安全：读操作无锁

**查找路径示例：**
```
查找 key="m"

Level 4: [HEAD] ------------------------------------------> [NULL]
Level 3: [HEAD] -------> [m] -----------------------------> [NULL]
Level 2: [HEAD] -> [e] -> [m] ---------------------------> [NULL]
Level 1: [HEAD] -> [e] -> [g] -> [m] --------------------> [NULL]
Level 0: [HEAD] -> [c] -> [e] -> [g] -> [m] -> [p] -----> [NULL]

查找步骤：
1. 从最高层开始，沿着 tower 指针向右移动
2. 如果下一个节点的 key < 目标 key，继续向右
3. 如果下一个节点的 key >= 目标 key，下降一层
4. 重复直到找到目标或到达底层
```

### 1.5 插入算法（Concurrent）

```go
func (s *Skiplist) Add(key []byte, v y.ValueStruct) {
    // 1. 生成随机高度
    height := s.randomHeight()
    
    // 2. 如果新高度 > 当前高度，更新高度
    for {
        h := s.getHeight()
        if height <= h {
            break
        }
        if s.height.CompareAndSwap(h, height) {
            break
        }
    }
    
    // 3. 查找插入位置（每层的前驱节点）
    var prev [maxHeight]*node
    var next [maxHeight]*node
    prev[height-1] = s.head
    for i := height - 1; i >= 0; i-- {
        // 查找第 i 层的插入位置
        prev[i], next[i] = s.findSpliceForLevel(key, prev[i], i)
        if prev[i] == next[i] {
            // 找到相同 key，更新 value
            prev[i].setValue(s.arena, v)
            return
        }
    }
    
    // 4. 分配新节点
    x := newNode(s.arena, key, v, height)
    
    // 5. 从底层到顶层，逐层插入（CAS）
    for i := 0; i < height; i++ {
        x.tower[i].Store(next[i].getNodeOffset(s.arena))
        if !prev[i].casNextOffset(i, next[i].getNodeOffset(s.arena), x.getOffset()) {
            // CAS 失败，重新查找
            prev[i], next[i] = s.findSpliceForLevel(key, s.head, i)
            for !prev[i].casNextOffset(i, next[i].getNodeOffset(s.arena), x.getOffset()) {
                prev[i], next[i] = s.findSpliceForLevel(key, prev[i], i)
            }
        }
    }
}
```

**并发控制：**
- 使用 CAS (Compare-And-Swap) 无锁插入
- 失败重试机制
- 从底向上插入，避免并发读取看到不完整结构

**仓颉实现要点：**
```cangjie
func add(key: Array<Byte>, value: ValueStruct) {
    // 1. 生成随机高度
    let height = randomHeight()
    
    // 2. 更新全局高度（CAS）
    while (true) {
        let h = getHeight()
        if (height <= h) { break }
        if (height.compareAndSwap(h, height)) { break }
    }
    
    // 3. 查找插入位置
    // ... (类似 Go 实现)
    
    // 4. 分配节点（Arena）
    let node = newNode(arena, key, value, height)
    
    // 5. 逐层 CAS 插入
    for (i in 0..height) {
        node.tower[i].store(next[i].offset)
        while (!prev[i].casNextOffset(i, next[i].offset, node.offset)) {
            // 重新查找
            (prev[i], next[i]) = findSpliceForLevel(key, head, i)
        }
    }
}
```

## 2. LSM Tree 合并与压缩算法

### 2.1 LSM Tree 基本概念

**层级结构：**
```
Level 0: MemTable (内存)
    ↓ Flush
Level 0: SSTables (可重叠)
    ↓ Compaction
Level 1: SSTables (不重叠)
    ↓ Compaction
Level 2: SSTables (不重叠)
    ↓
...
Level 6: SSTables (不重叠)
```

**关键特性：**
- Level 0: 由 MemTable Flush 产生，允许 key 范围重叠
- Level 1-6: 通过 Compaction 产生，key 范围不重叠
- 容量限制：Level L 的总大小 ≤ 10^L MB（可配置）

### 2.2 Compaction 触发条件

```go
// 触发条件检查
func (s *levelsController) pickCompactLevels() (bool, *compactDef) {
    // 1. 检查 Level 0 表数量
    if len(s.levels[0].tables) > s.kv.opt.NumLevelZeroTables {
        return s.pickCompactLevel(0)
    }
    
    // 2. 检查每层大小
    for i := 1; i < len(s.levels); i++ {
        if s.levels[i].totalSize > s.kv.opt.LevelSizeMultiplier*s.levels[i-1].totalSize {
            return s.pickCompactLevel(i)
        }
    }
    
    return false, nil
}
```

**触发规则：**
1. **Level 0**: 表数量超过阈值（默认 5）
2. **Level 1-6**: 大小超过上层的倍数（默认 10 倍）
3. **手动触发**: 用户调用 `DB.RunValueLogGC()`

### 2.3 Compaction 执行流程

```go
type compactDef struct {
    thisLevel   *levelHandler
    nextLevel   *levelHandler
    top         []*table.Table  // 当前层要压缩的表
    bot         []*table.Table  // 下一层重叠的表
    thisRange   keyRange
    nextRange   keyRange
    split       keyRange
    t           *btree.BTree    // 用于合并排序
}
```

**执行步骤：**

1. **选择 Compaction 范围**
```go
func (s *levelHandler) pickCompact() (*compactDef, bool) {
    // 从第一个表开始
    cd := &compactDef{thisLevel: s}
    cd.top = []*table.Table{s.tables[0]}
    
    // 扩展范围（基于 key range）
    cd.thisRange = getKeyRange(cd.top...)
    
    // 查找下一层重叠的表
    cd.bot = s.nextLevel.overlappingTables(cd.thisRange)
    cd.nextRange = getKeyRange(cd.bot...)
    
    return cd, true
}
```

2. **合并排序（Merge Sort）**
```go
func (s *levelsController) compactTables(cd *compactDef) error {
    // 创建迭代器（多路归并）
    it := table.NewConcatIterator(cd.top, false)
    it.Next()
    
    // 创建 Builder
    builder := table.NewTableBuilder()
    
    // 遍历所有 key-value
    for ; it.Valid(); it.Next() {
        key := it.Key()
        val := it.Value()
        
        // 写入新表
        builder.Add(key, val)
        
        // 如果表大小达到阈值，生成新表
        if builder.ReachedCapacity() {
            tbl := builder.Build()
            cd.newTables = append(cd.newTables, tbl)
            builder = table.NewTableBuilder()
        }
    }
    
    return nil
}
```

3. **更新 MANIFEST**
```go
func (s *levelsController) installCompactionResults(cd *compactDef) error {
    // 1. 删除旧表
    changes := make([]*pb.ManifestChange, 0)
    for _, tbl := range cd.top {
        changes = append(changes, newDeleteChange(tbl.ID()))
    }
    for _, tbl := range cd.bot {
        changes = append(changes, newDeleteChange(tbl.ID()))
    }
    
    // 2. 添加新表
    for _, tbl := range cd.newTables {
        changes = append(changes, 
            newCreateChange(tbl.ID(), cd.nextLevel.level, 0, 0))
    }
    
    // 3. 写入 MANIFEST
    return s.kv.manifest.addChanges(changes)
}
```

**合并策略示例：**
```
Compaction 示例（Level 1 -> Level 2）

Level 1:
  [1.sst: a-e] [2.sst: f-j] [3.sst: k-o]
         ↓ Compaction (选择 2.sst)
Level 2:
  [10.sst: a-c] [11.sst: d-g] [12.sst: h-l] [13.sst: m-p]
  
合并过程：
1. 读取 2.sst (f-j) 和重叠表 [11.sst, 12.sst]
2. 多路归并排序：
   - 来自 2.sst 的 key（新版本）优先
   - 删除标记的 key 不写入
   - 过期的 key 不写入
3. 生成新表：
   [20.sst: d-f] [21.sst: g-h] [22.sst: i-l]
4. 原子性替换：
   - 删除：2.sst, 11.sst, 12.sst
   - 添加：20.sst, 21.sst, 22.sst
```

### 2.4 写放大优化（WiscKey）

**传统 LSM 问题：**
- 每次写入都要写完整的 KV 对
- Compaction 时重复移动大 Value
- 写放大严重（可达 10-50 倍）

**WiscKey 解决方案：**
```
传统 LSM:
  SSTable: [Key1+Value1] [Key2+Value2] [Key3+Value3]
  
WiscKey (BadgerDB):
  SSTable: [Key1+VP1] [Key2+VP2] [Key3+VP3]
           ↓           ↓           ↓
  Value Log: [Value1] [Value2] [Value3]
```

**优化效果：**
- SSTable 只存储 Key（小）+ ValuePointer（16 字节）
- Value Log 顺序追加，不参与 Compaction
- 写放大降低 90%+

## 3. Value Log GC 算法

### 3.1 GC 必要性

**问题：**
- Value Log 只追加，不修改
- 数据更新/删除后，旧值仍在 Value Log
- 磁盘空间持续增长

**解决：**
- 定期 GC（Garbage Collection）
- 重写有效数据，删除无效数据

### 3.2 GC 触发条件

```go
func (vlog *valueLog) runGC() error {
    // 1. 选择候选文件（最老的文件）
    lf := vlog.pickVlogFile()
    if lf == nil {
        return ErrNoRewrite
    }
    
    // 2. 统计垃圾比例
    stat := vlog.garbageStat(lf)
    discardRatio := float64(stat.discard) / float64(stat.total)
    
    // 3. 如果垃圾比例 < 阈值，不执行 GC
    if discardRatio < vlog.opt.ValueLogGarbageCollectionRatio {
        return nil
    }
    
    // 4. 执行 GC
    return vlog.rewrite(lf)
}
```

**触发策略：**
1. **被动触发**: 用户调用 `DB.RunValueLogGC()`
2. **主动触发**: 后台线程定期检查
3. **阈值**: 垃圾比例 > 0.5（默认）

### 3.3 GC 执行流程

```go
func (vlog *valueLog) rewrite(f *logFile) error {
    // 1. 遍历旧文件中的所有 Entry
    entries := make([]*Entry, 0)
    f.iterate(func(e Entry) error {
        // 2. 检查 Entry 是否仍然有效
        vs, err := vlog.db.get(e.Key)
        if err != nil {
            return err
        }
        
        // 3. 如果已删除或已更新，跳过
        if discardEntry(e, vs, vlog.db) {
            return nil
        }
        
        // 4. 有效 Entry 加入列表
        entries = append(entries, &e)
        return nil
    })
    
    // 5. 批量写入新文件
    wb := vlog.db.newWriteBatch()
    for _, e := range entries {
        wb.setEntry(e)
    }
    wb.flush()
    
    // 6. 删除旧文件
    vlog.deleteFile(f.fid)
    
    return nil
}

// 检查 Entry 是否应该丢弃
func discardEntry(e Entry, vs y.ValueStruct, db *DB) bool {
    // 1. Key 已被删除
    if vs.Meta&bitDelete != 0 {
        return true
    }
    
    // 2. Value 已更新（ValuePointer 不同）
    if len(vs.Value) == 0 {
        return true
    }
    
    vp := valuePointer{}
    vp.Decode(vs.Value)
    if vp.Fid != e.fid || vp.Offset != e.offset {
        return true
    }
    
    // 3. 已过期
    if e.ExpiresAt > 0 && time.Now().Unix() >= e.ExpiresAt {
        return true
    }
    
    return false
}
```

**GC 流程示例：**
```
原始 Value Log (000001.vlog, 100MB):
  [Key1=Val1] [Key2=Val2] [Key1=Val1'] [Key3=Val3] [Key2=DELETE]
  
GC 执行后 (000002.vlog, 30MB):
  [Key1=Val1'] [Key3=Val3]
  
垃圾回收：
  - Key1=Val1: 已被 Val1' 更新 → 丢弃
  - Key2=Val2: 已被删除 → 丢弃
  - Key2=DELETE: 删除标记 → 丢弃
  - 有效数据：30MB (30%)
```

## 4. 事务隔离算法（SSI）

### 4.1 SSI (Serializable Snapshot Isolation)

**隔离级别：**
- Read Committed: 读已提交
- Repeatable Read: 可重复读
- **Serializable: 可串行化** ← BadgerDB 使用

**SSI 原理：**
- 基于时间戳的多版本并发控制（MVCC）
- 读写冲突检测
- 乐观并发控制

### 4.2 事务时间戳管理

```go
type oracle struct {
    sync.Mutex
    nextTxnTs uint64  // 下一个可用时间戳
    readMark  *WaterMark  // 读时间戳水位线
    txnMark   *WaterMark  // 提交时间戳水位线
    committedTxns []committedTxn  // 已提交事务
}

type committedTxn struct {
    ts uint64
    conflictKeys map[uint64]struct{}  // 写入的 Key
}
```

**时间戳分配：**
```
时间线：
  0 ---- 10 ---- 20 ---- 30 ---- 40 ---- 50
         ↑       ↑       ↑       ↑
       Txn1    Txn2    Txn3    Txn4
       
规则：
- 全局递增的 uint64
- 每个事务获取唯一的读时间戳和提交时间戳
```

### 4.3 读写流程

**1. 读操作（Read）**
```go
func (txn *Txn) Get(key []byte) (y.ValueStruct, error) {
    // 1. 使用事务的读时间戳
    readTs := txn.readTs
    
    // 2. 查找所有版本
    versions := txn.db.getVersions(key)
    
    // 3. 选择 <= readTs 的最新版本
    for _, v := range versions {
        if v.version <= readTs {
            return v, nil
        }
    }
    
    return nil, ErrKeyNotFound
}
```

**2. 写操作（Write）**
```go
func (txn *Txn) Set(key, value []byte) error {
    // 1. 记录写入
    txn.writes[key] = value
    
    // 2. 检查读冲突（延迟到提交时）
    return nil
}

func (txn *Txn) Commit() error {
    // 1. 获取提交时间戳
    commitTs := txn.db.oracle.nextTs()
    
    // 2. 检查读写冲突
    for key := range txn.reads {
        if txn.db.oracle.hasConflict(key, txn.readTs, commitTs) {
            return ErrConflict
        }
    }
    
    // 3. 写入 MemTable
    for key, value := range txn.writes {
        entry := &Entry{
            Key:   key,
            Value: value,
            version: commitTs,
        }
        txn.db.mt.Put(entry)
    }
    
    // 4. 更新水位线
    txn.db.oracle.doneCommit(commitTs)
    
    return nil
}
```

**3. 冲突检测**
```go
func (o *oracle) hasConflict(key []byte, readTs, commitTs uint64) bool {
    o.Lock()
    defer o.Unlock()
    
    // 检查在 [readTs, commitTs) 区间内是否有其他事务写入了相同 key
    for _, txn := range o.committedTxns {
        if txn.ts > readTs && txn.ts < commitTs {
            if _, ok := txn.conflictKeys[hash(key)]; ok {
                return true  // 冲突！
            }
        }
    }
    
    return false
}
```

**冲突示例：**
```
时间线：
  T1: Read(A, ts=10) ---- Write(A) ---- Commit(ts=20)
                                      ↑
  T2:      Read(A, ts=15) ------------------------ Write(A) -- Commit(ts=25)?
                                               ↑
                                          冲突检测！

T2 提交时检测到：
- T1 在 [15, 25) 区间内写入了 A
- T2 也读取了 A
- 读写冲突 → T2 回滚
```

### 4.4 Snapshot 实现

```go
type Snapshot struct {
    db  *DB
    ts  uint64  // 快照时间戳
}

func (s *Snapshot) Get(key []byte) (y.ValueStruct, error) {
    // 只能看到 ts 之前的数据
    return s.db.getAt(key, s.ts)
}
```

**快照特性：**
- 创建快照时获取当前读时间戳
- 后续读操作看到的数据不会变化
- 提供 Repeatable Read 隔离级别

## 5. 实现建议

### 5.1 仓颉语言适配

**Skiplist 并发控制：**
```cangjie
// 使用 Atomic<Int32> 代替 atomic.Int32
class Node {
    let value: Atomic<UInt64>
    let keyOffset: UInt32
    let keySize: UInt16
    let height: UInt16
    let tower: Array<Atomic<UInt32>>
    
    init(arena: Arena, key: Array<Byte>, value: ValueStruct, height: Int) {
        // ...
    }
    
    func casNextOffset(level: Int, old: UInt32, new: UInt32): Bool {
        return tower[level].compareAndSwap(old, new)
    }
}
```

**Arena 内存管理：**
```cangjie
class Arena {
    let buf: Array<Byte>
    let n: Atomic<UInt32>
    
    func putNode(height: Int): UInt32 {
        let unusedSize = (MAX_HEIGHT - height) * OFFSET_SIZE
        let size = UInt32(MAX_NODE_SIZE - unusedSize + NODE_ALIGN)
        let offset = n.add(size)
        
        // 检查溢出
        if (offset > buf.size) {
            panic("Arena too small")
        }
        
        // 返回对齐的偏移量
        return (offset - size + UInt32(NODE_ALIGN)) & ~UInt32(NODE_ALIGN)
    }
    
    func getNode(offset: UInt32): Node {
        if (offset == 0) { return null }
        
        // 仓颉无法直接转换，需要手动解析
        // 或者使用更简单的实现：返回偏移量，外部解析
        return new Node(this, offset)
    }
}
```

### 5.2 性能优化建议

**1. 减少内存分配**
```cangjie
// 重用 Buffer
let buffer = arena.allocate(1024)
// ... 使用 buffer
arena.reset()  // 重置而不是重新分配
```

**2. 批量操作**
```cangjie
// 使用 WriteBatch 批量写入
let batch = db.newWriteBatch()
for (i in 0..1000) {
    batch.set(key[i], value[i])
}
batch.flush()  // 一次性提交
```

**3. 并发控制**
```cangjie
// 使用细粒度锁
class DB {
    let lock: ReentrantLock
    let mt: MemTable
    let imm: Array<MemTable>
    
    func get(key: Array<Byte>): Option<Array<Byte>> {
        // 读操作：无锁或读锁
        lock.readLock()
        defer { lock.readUnlock() }
        
        // ...
    }
    
    func set(key: Array<Byte>, value: Array<Byte>) {
        // 写操作：写锁
        lock.writeLock()
        defer { lock.writeUnlock() }
        
        // ...
    }
}
```

## 6. 测试策略

### 6.1 单元测试

**Skiplist 测试：**
```cangjie
@Test
func testSkiplistConcurrentInsert() {
    let skl = Skiplist.new(1 << 20)
    let threads = 10
    let keysPerThread = 1000
    
    // 并发插入
    let futures = Array<Future<Unit>>(threads)
    for (i in 0..threads) {
        futures[i] = async {
            for (j in 0..keysPerThread) {
                let key = "key-${i}-${j}"
                skl.add(key.toBytes(), "value".toBytes())
            }
        }
    }
    
    // 等待完成
    for (f in futures) { f.await() }
    
    // 验证所有 key 都存在
    for (i in 0..threads) {
        for (j in 0..keysPerThread) {
            let key = "key-${i}-${j}"
            assert(skl.get(key.toBytes()) != null)
        }
    }
}
```

### 6.2 性能测试

**基准测试：**
```cangjie
@Benchmark
func benchmarkRandomRead() {
    let db = DB.open("/tmp/bench")
    
    let start = System.currentTimeMillis()
    for (i in 0..100000) {
        let key = randomKey()
        db.get(key)
    }
    let elapsed = System.currentTimeMillis() - start
    
    println("Throughput: ${100000.0 / elapsed * 1000} ops/s")
}
```

---

**参考文献：**
- [Skip Lists: A Probabilistic Alternative to Balanced Trees](https://15721.courses.cs.cmu.edu/spring2018/papers/01-pugh.pdf)
- [WiscKey: Separating Keys from Values in SSD-conscious Storage](https://www.usenix.org/system/files/conference/fast16/fast16-papers-lu.pdf)
- [The Log-Structured Merge-Tree (LSM-Tree)](https://www.cs.umb.edu/~poneil/lsmtree.pdf)
