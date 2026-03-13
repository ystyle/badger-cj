# Phase 7 设计：完整 Compaction + VLog GC

**日期：** 2026-03-13  
**状态：** 设计完成，待实现  
**优先级：** 🔴 最高

---

## 背景

当前 Compaction 实现是极度简化版，只做表移动，不合并数据：

```cangjie
// 当前实现（错误）
for (table in tables) {
    l1Handler.addTable(table)  // 直接移动，不合并
}
l0Handler.clearTables()
```

**问题：**
1. 删除标记永远不会被清理
2. 旧版本 key 永远不会被清理
3. 磁盘空间不会回收
4. 读取性能下降（要检查更多表）

**VLog 也缺少 GC：**
- 被删除/覆盖的大值仍占用磁盘空间
- VLog 文件无限增长

---

## 目标

1. 实现完整多层级 Compaction（L0→L1→...→L6）
2. 实现 VLog GC 自动回收磁盘空间
3. 支持自动后台 + 手动触发两种方式

---

## 一、Compaction 架构

### 1.1 整体架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Badger (DB)                               │
│  ┌─────────────────┐    ┌─────────────────────────────────┐ │
│  │ LevelsController│◄───│ Compactor (后台协程)            │ │
│  │  ┌───────────┐  │    │  - runCompactor() 循环          │ │
│  │  │ Level 0   │  │    │  - pickCompaction() 选择任务    │ │
│  │  │ Level 1   │  │    │  - doCompact() 执行             │ │
│  │  │ ...       │  │    └─────────────────────────────────┘ │
│  │  │ Level 6   │  │                                      │
│  │  └───────────┘  │    ┌─────────────────────────────────┐ │
│  │  compactStatus  │◄───│ compactionPriority 队列         │ │
│  └─────────────────┘    │  - L0 表数量                     │ │
│                         │  - 层大小比例                     │ │
│                         └─────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 核心数据结构

#### keyRange - SSTable 的 key 范围

```cangjie
struct keyRange {
    let left: Array<Byte>   // 最小 key（带时间戳）
    let right: Array<Byte>  // 最大 key（带时间戳）
    let inf: Bool           // 是否无限范围

    // 方法
    public func isEmpty(): Bool
    public func overlapsWith(other: keyRange): Bool
    public func extend(other: keyRange): Unit
}
```

#### levelCompactStatus - 每层的 Compaction 状态

```cangjie
struct levelCompactStatus {
    let ranges: ArrayList<keyRange>  // 正在 Compaction 的 key 范围
    let delSize: Int64               // 已删除的总大小

    public func overlapsWith(range: keyRange): Bool
    public func remove(range: keyRange): Bool
}
```

#### compactStatus - 全局 Compaction 状态

```cangjie
class compactStatus {
    private let lock: RWMutex
    private let levels: ArrayList<levelCompactStatus>
    private let tables: HashSet<UInt64>  // 正在 Compaction 的表 ID

    // 检查是否与现有 Compaction 重叠
    public func overlapsWith(level: Int, range: keyRange): Bool
    
    // 尝试添加 Compaction 任务（原子操作）
    public func compareAndAdd(cd: compactDef): Bool
    
    // 完成 Compaction 后清理状态
    public func delete(cd: compactDef): Unit
}
```

#### compactionPriority - Compaction 优先级

```cangjie
struct compactionPriority {
    let level: Int       // 哪一层需要 Compaction
    let score: Float64   // 优先级分数，越大越优先

    // 分数计算
    // L0: 表数量 / NumLevelZeroTables
    // L1+: 层大小 / levelMaxSize
}
```

#### compactDef - Compaction 任务定义

```cangjie
struct compactDef {
    let thisLevel: Int                           // 源层
    let nextLevel: Int                           // 目标层
    let top: ArrayList<TableAdapter>             // 源层被选中的表
    let bot: ArrayList<TableAdapter>             // 目标层重叠的表
    let thisRange: keyRange                      // 源层 key 范围
    let nextRange: keyRange                      // 目标层 key 范围
    let splits: ArrayList<keyRange>              // 分片（大 Compaction）
    let thisSize: Int64                          // 源层表总大小

    public func isEmpty(): Bool
}
```

### 1.3 Compaction 流程

#### 步骤 1：pickCompaction() - 选择 Compaction 任务

```
1. 收集所有层的 compactionPriority
   - L0: score = numTables / NumLevelZeroTables
   - L1+: score = levelSize / levelMaxSize

2. 选择 score > 1.0 的最高优先级

3. 如果 L0 score 最高：
   - 选择所有 L0 表
   - 目标层 = L1（或 Lbase）

4. 如果其他层 score 最高：
   - 选择该层部分表
   - 目标层 = 下一层

5. 返回 compactDef
```

#### 步骤 2：fillTables() - 填充表列表

```
1. 获取源层被选中的表 (top)

2. 计算源层的 keyRange

3. 在目标层查找重叠的表 (bot)
   - 遍历目标层所有表
   - 选择 keyRange 与源层重叠的表

4. 检查 compactStatus 是否可执行
   - thisRange 和 nextRange 不能与现有 Compaction 重叠
   - 所有表不能正在被其他 Compaction 使用
```

#### 步骤 3：runCompactDef() - 执行 Compaction

```
1. compactBuildTables() - 合并并生成新表
   ├── 创建 MergeIterator（合并 top + bot 的迭代器）
   ├── 遍历所有 key
   │   ├── 丢弃删除标记（目标层非最后一层）
   │   ├── 丢弃旧版本（只保留最新版本）
   │   └── 写入新 SSTable
   └── 返回新表列表

2. buildChangeSet() - 构建变更集
   - 删除的表：top + bot
   - 新增的表：newTables

3. 更新 MANIFEST
   - 写入变更记录

4. 替换表
   - nextLevel.replaceTables(bot, newTables)
   - thisLevel.deleteTables(top)

5. 清理 compactStatus
```

### 1.4 MergeIterator 实现

合并多个 SSTable 的迭代器：

```cangjie
class MergeIterator {
    private let iters: ArrayList<TableIterator>
    private let heap: MinHeap<TableIterator>  // 按 key 排序
    
    public func next(): Bool
    public func key(): Array<Byte>
    public func value(): ValueStruct
    public func valid(): Bool
}
```

### 1.5 丢弃策略

#### 丢弃删除标记 (Drop Tombstone)

```cangjie
// 目标层不是最后一层时，丢弃删除标记
if (nextLevel < maxLevel && vs.isDelete()) {
    continue  // 跳过，不写入新表
}
```

#### 丢弃旧版本 (Drop Old Versions)

```cangjie
// 只保留最新版本
// 由于迭代器按 key 时间戳降序排列，第一个遇到的就是最新版本
var lastKey: ?Array<Byte> = None
while (iter.valid()) {
    let key = parseKey(iter.key())  // 去掉时间戳
    if (lastKey.isSome() && keysEqual(key, lastKey!!)) {
        iter.next()
        continue  // 跳过旧版本
    }
    lastKey = Some(key)
    // 写入新表
}
```

---

## 二、VLog GC 架构

### 2.1 整体架构

```
┌─────────────────────────────────────────────────────────────┐
│                    VLogManager                               │
│  ┌─────────────────┐    ┌─────────────────────────────────┐ │
│  │ VLog 文件管理   │    │ GC 后台协程                     │ │
│  │  - files[]      │    │  - waitOnGC() 循环              │ │
│  │  - offsetMap    │    │  - runGC() 执行                 │ │
│  └─────────────────┘    └─────────────────────────────────┘ │
│                                                              │
│  ┌─────────────────────────────────────────────────────────┐│
│  │ GC 统计                                                   ││
│  │  - 每个文件的垃圾比例 = 已删除/已覆盖 / 总大小          ││
│  │  - discardRatio 阈值 (默认 0.5)                          ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

### 2.2 VLog GC 流程

#### 步骤 1：pickVLogForGC() - 选择 VLog 文件

```
1. 遍历所有 VLog 文件

2. 计算垃圾比例
   - 需要统计每个 entry 是否有效
   - 有效 = SSTable 中的 ValuePointer 指向该 entry

3. 选择垃圾比例 > discardRatio 的文件
```

#### 步骤 2：runGC() - 执行 GC

```
1. 读取 VLog 文件所有 entry

2. 检查每个 entry 是否有效
   - 从 SSTable 查找 key 的 ValuePointer
   - 如果指针 != 当前 entry 的位置，说明已过期

3. 将有效 entry 写入新 VLog 文件
   - 记录旧 offset -> 新 offset 映射

4. 更新 SSTable 中的 ValuePointer
   - 需要重写包含该 key 的 SSTable
   - 或使用间接层（offsetMap）

5. 更新 MANIFEST

6. 删除旧 VLog 文件
```

### 2.3 简化方案：ValuePointer 间接层

为避免 GC 时重写 SSTable，使用 offsetMap 作为间接层：

```cangjie
class VLogManager {
    // fid -> (oldOffset -> newOffset)
    private let offsetMaps: HashMap<UInt64, HashMap<UInt32, UInt32>>
    
    // 读取时先查 offsetMap
    public func read(vp: ValuePointer): LogEntry {
        let newOffset = offsetMaps[vp.fid]?.get(vp.offset) ?? vp.offset
        return files[vp.fid].read(newOffset)
    }
}
```

**优点：**
- 不需要重写 SSTable
- GC 更快

**缺点：**
- offsetMap 需要持久化
- 读性能略有下降

### 2.4 VLog GC 配置

```cangjie
public class Config {
    // ... 现有配置 ...
    
    // VLog GC 相关
    public let ValueLogGCThreshold: Float64  // 默认 0.5
    public let ValueLogGCFrequency: Duration // 默认 10m
}
```

---

## 三、文件结构变更

### 3.1 新增文件

```
src/db/
├── compact_status.cj      # compactStatus + keyRange
├── compact_def.cj         # compactDef + compactionPriority
└── vlog_gc.cj             # VLog GC 实现

src/db/compaction.cj       # 重写为完整版本
```

### 3.2 修改文件

```
src/db/badger.cj           # 添加 compact() 手动接口
src/db/levels.cj           # 添加 compactStatus + Compactor
src/vlog/vlog_manager.cj   # 添加 GC 相关方法
```

---

## 四、测试策略

### 4.1 Compaction 测试

| 测试 | 描述 |
|------|------|
| testCompactionBasic | L0→L1 基本合并 |
| testCompactionDropTombstone | 丢弃删除标记 |
| testCompactionDropOldVersions | 丢弃旧版本 |
| testCompactionMultiLevel | 多层级 Compaction |
| testCompactionConcurrent | 并发 Compaction 正确性 |
| testCompactionReadDuring | Compaction 期间读取正确 |
| testCompactionRestart | Compaction 中断后恢复 |

### 4.2 VLog GC 测试

| 测试 | 描述 |
|------|------|
| testVLogGCBasic | 基本垃圾回收 |
| testVLogGCWithOverwrite | 覆盖后 GC |
| testVLogGCWithDelete | 删除后 GC |
| testVLogGCUpdatesPointers | 正确更新指针 |
| testVLogGCMultipleFiles | 多文件 GC |
| testVLogGCLargeValue | 大值 GC |

---

## 五、实现顺序

### P0: Compaction (~16h)

1. **compact_status.cj** - keyRange + compactStatus (~2h)
2. **compact_def.cj** - compactDef + compactionPriority (~2h)
3. **levels.cj 修改** - 添加 compactStatus (~2h)
4. **compaction.cj 重写** - pickCompaction + doCompact (~4h)
5. **MergeIterator** - 合并多个 SSTable (~2h)
6. **Compactor 后台协程** - 自动触发 (~2h)
7. **测试** - Compaction 测试 (~2h)

### P1: VLog GC (~12h)

1. **vlog_gc.cj** - pickVLogForGC + runGC (~4h)
2. **VLogManager 修改** - offsetMap + GC 集成 (~4h)
3. **GC 后台协程** - 自动触发 (~2h)
4. **测试** - VLog GC 测试 (~2h)

---

## 六、参考

- Go Badger compaction.go
- Go Badger levels.go (runCompactDef, doCompact)
- Go Badger vlog.go (runGC)