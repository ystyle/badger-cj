# VLog GC 完整实现设计

**日期：** 2026-03-13
**状态：** ✅ 已完成

---

## 背景

当前 VLog GC 是简化版本：
- `getDiscardRatio()` 返回固定值 0.5
- `runGC()` 直接删除文件，不重写有效数据

**问题：** 会丢失有效数据！

---

## 目标

实现完整的 VLog GC，参考 Go Badger 的实现：

1. ✅ 跟踪每个 VLog 文件的垃圾统计
2. ✅ 选择垃圾最多的文件进行 GC
3. ✅ 重写有效 entry 到新 VLog 文件
4. ✅ 删除旧文件，回收磁盘空间

---

## 设计

### 架构

```
┌─────────────────────────────────────────────────────────────┐
│                      Badger                                  │
│  ┌─────────────────┐    ┌─────────────────────────────────┐ │
│  │ DiscardStats    │    │ VLogManager                      │ │
│  │  - stats: Map   │◄───│  - pickLog(discardRatio)         │ │
│  │    fid -> bytes │    │  - rewrite(fid)                  │ │
│  └─────────────────┘    │  - iterate(fid, callback)        │ │
│         ▲               └─────────────────────────────────┘ │
│         │                                                    │
│  ┌──────┴──────────┐                                        │
│  │ delete/set      │ 更新 discard stats                     │
│  └─────────────────┘                                        │
└─────────────────────────────────────────────────────────────┘
```

### 核心组件

#### 1. DiscardStats

跟踪每个 VLog 文件的垃圾大小：

```cangjie
public class DiscardStats {
    private let lock: Mutex
    private var stats: HashMap<UInt32, Int64>  // fid -> discard bytes
    private let filePath: Path
    private let data: ArrayList<Byte>
    
    public init(filePath: Path)
    
    // 更新垃圾统计（discard > 0 增加，< 0 清零）
    public func update(fid: UInt32, discard: Int64): Int64
    
    // 获取垃圾最多的文件
    public func maxDiscard(): (UInt32, Int64)
    
    // 持久化到文件
    public func flush(): Unit
}
```

#### 2. VLogManager 增强

```cangjie
public class VLogManager {
    private let db: Badger  // 新增：用于查找 LSM Tree
    private let discardStats: DiscardStats  // 新增
    
    // 选择垃圾比例超过阈值的文件
    public func pickLog(discardRatio: Float64): ?UInt32
    
    // 重写有效 entry 到新文件
    public func rewrite(fid: UInt32): Bool
    
    // 遍历 VLog 文件
    public func iterate(fid: UInt32, callback: (LogEntry) -> Bool): Unit
    
    // 完整 GC
    public func runGC(discardRatio: Float64): Bool
}
```

#### 3. GC 流程

```
runGC(discardRatio):
  1. fid = pickLog(discardRatio)
  2. if fid == None: return false
  3. return rewrite(fid)

rewrite(fid):
  1. iterate(fid, checkAndRewrite)
  2. deleteFile(fid)
  3. return true

checkAndRewrite(entry):
  1. vs = db.get(entry.key)
  2. if vs == None: return  // key 已删除
  3. vp = ValuePointer.decode(vs.value)
  4. if vp.fid != fid || vp.offset != entry.offset: return  // 已过期
  5. db.set(entry.key, entry.value)  // 重写到新位置
```

### 数据流

```
写入大值:
  1. db.set("key", largeValue)
  2. largeValue 写入 VLog (fid=1, offset=100)
  3. SSTable 存储 ValuePointer{fid=1, offset=100}

删除/覆盖:
  1. db.delete("key")
  2. discardStats.update(1, len(largeValue))
  3. SSTable 存储 delete marker

GC:
  1. pickLog(0.5) → fid=1 (discard > 50%)
  2. iterate fid=1:
     - entry: key, largeValue, offset=100
     - db.get("key") → delete marker
     - 跳过（已删除）
  3. deleteFile(1)
  4. 磁盘空间回收
```

---

## 实现步骤

### Step 1: DiscardStats 类 ✅

- 创建 `src/vlog/discard_stats.cj`
- 实现 `update()`, `maxDiscard()`, `flush()`
- 支持持久化到 `DISCARD` 文件

### Step 2: VLogManager 增强 ✅

- 创建 `src/vlog/vlog_gc_db.cj` 接口打破循环依赖
- 添加 `db: VLogGCDB` 引用
- 添加 `discardStats: DiscardStats`
- 实现 `iterate()` 遍历方法

### Step 3: pickLog 实现 ✅

- 遍历所有 VLog 文件
- 计算垃圾比例 = discardStats[fid] / fileSize
- 选择比例最大的文件

### Step 4: rewrite 实现 ✅

- 创建 `src/vlog/gc_file_rewriter.cj` 批量重写器
- 遍历选定文件的所有 entry
- 对每个 entry，检查 LSM Tree 的 ValuePointer
- 如果匹配，重写到 DB
- 删除旧文件

### Step 5: Badger 集成 ✅

- 实现 `VLogGCDB` 接口
- `updateDiscardStats()` 在 delete/set 时更新统计
- 后台协程每 60 秒执行一次 GC

### Step 6: 测试 ✅

- `VLogGCTest`: 3 个测试用例
- `VLogManagerGCTest`: 6 个测试用例
- 测试 iterate/pickLog/rewrite 正确性

---

## 注意事项

1. **并发安全**：GC 期间可能有写入，需要加锁
2. **迭代器检查**：如果有活跃迭代器，延迟删除文件
3. **批量重写**：避免一次重写太多数据，分批处理
4. **持久化**：discardStats 需要持久化到文件