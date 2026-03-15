# 仓颉开发经验与技术决策记录

本文档记录 badger-cj 项目开发过程中积累的仓颉语言开发经验、踩过的坑、优化技巧和架构决策。

---

## 一、仓颉语言陷阱

### 1.1 Atomic 类型陷阱

#### fetchAdd 返回旧值

```cangjie
// 错误理解
let newVal = atomic.fetchAdd(1)  // 返回的是旧值，不是新值！

// 正确用法
let oldVal = atomic.fetchAdd(1)
let newVal = oldVal + 1
```

#### Array repeat: 初始化引用类型

```cangjie
// 错误：所有元素共享同一个对象
let arr = Array<AtomicUInt32>(10, repeat: AtomicUInt32(0))

// 正确：使用闭包创建独立对象
let arr = Array<AtomicUInt32>(10, { _ => AtomicUInt32(0) })
```

**影响**：`src/skiplist/atomic_storage.cj` 中 AtomicStorage 初始化

### 1.2 类型转换

#### UInt64 vs Int64

```cangjie
// 错误：as UInt64 可能溢出
let x = -1i64 as UInt64  // 行为不确定

// 正确：使用 UInt64() 构造
let x = UInt64(someValue)
```

### 1.3 并发与内存

#### Option 类型线程安全

```cangjie
// Option<T> 本身不是线程安全的
// 多线程访问需要用 AtomicReference<Option<T>>
```

#### spawn 返回值

```cangjie
// spawn 返回 Future<Unit>，忽略要用 let _
spawn { ... }  // 警告：未使用返回值
let _ = spawn { ... }  // 正确
```

### 1.4 语法细节

| 陷阱 | 说明 |
|------|------|
| `let` vs `const` | `let` 定义常量，不是 `const` |
| `Array<T>(size, repeat:)` | 初始化语法，不是 `new Array` |
| `.add()` vs `.append()` | ArrayList 用 `add`，不是 `append` |
| `while(true)` 返回值 | 需确保所有路径有返回值 |
| `let` 变量重赋值 | `let` 变量在 `while` 内不能重新赋值，需用 `var` |
| `@OverflowWrapping` | 整数溢出需显式标注，否则运行时错误 |

---

## 二、性能优化经验

### 2.1 内存分配优化

#### ArrayList 预分配

```cangjie
// 差：动态扩容多次复制
let list = ArrayList<Byte>()
for (i in 0..10000) { list.add(i) }

// 好：预分配容量
let list = ArrayList<Byte>(10000)
```

**效果**：写入性能提升 ~10%

#### 批量拷贝替代逐字节

```cangjie
// 差：逐字节拷贝
for (b in data) { buf.add(b) }

// 好：批量拷贝
data.copyTo(buf, 0, buf.size, data.size)
```

**效果**：LogEntry.encode 性能提升 50-60%

### 2.2 对象创建优化

#### 减少 Node 对象创建

```cangjie
// 差：每次比较创建 Node 对象
let node = Node(storage, offset)
let cmp = node.compareKey(key)

// 好：直接访问 Arena buffer
let keyData = storage.getBytes(offset + KEY_OFFSET, keyLen)
compareBytes(keyData, key)
```

**效果**：SkipList.add 减少 50% 对象创建

#### 延迟初始化

```cangjie
// MemTableIterator 延迟迭代
// 正向：O(1) 初始化，首次 next() 时定位
// 反向：保留预加载（需要先定位到末尾）
```

**效果**：正向迭代初始化从 O(n) 降到 O(1)

### 2.3 并发优化

#### Condition 替代轮询

```cangjie
// 差：轮询等待
while (!ready) { sleep(1ms) }

// 好：Condition 通知
let cond = Condition()
cond.wait(lock)  // 等待
cond.signalAll()  // 通知
```

**效果**：大事务延迟从 ~100ms 降到 ~1ms

#### 请求对象池化

```cangjie
// 复用 WriteRequest 对象，减少 GC 压力
class WriteRequestPool {
    let pool = Array<WriteRequest>(100, { _ => WriteRequest() })
}
```

**效果**：小事务性能提升 ~10%

### 2.4 CRC32C 优化

```cangjie
// 差：每次创建查找表
let table = makeCRCTable()

// 好：全局查找表
let globalTable = Array<UInt32>(256, { i => computeCRCEntry(i) })
```

**效果**：CRC 开销从 17% 降到 0.04%

---

## 三、架构设计决策

### 3.1 Entry.meta vs userMeta 分离

**问题**：如果 userMeta 用于判断 isDelete()，用户设置 withMeta(0x55) 会触发误删（0x55 包含 bitDelete 位）。

**方案**：
```cangjie
public class Entry {
    public let meta: Byte       // 内部标记 (bitDelete, bitDiscardEarlier)
    public let userMeta: Byte   // 用户自定义 (任意值 0x00-0xFF)
}
```

**相关提交**：`9709d26`

### 3.2 VLog GC 循环依赖

**问题**：Badger 需要调用 VLogManager.runGC()，VLogManager 需要 Badger.setRaw() 重写数据。

**方案**：定义接口解耦
```cangjie
public interface VLogGCDB {
    func getVS(key: Array<Byte>): ?ValueStruct
    func setRaw(key: Array<Byte>, value: Array<Byte>, meta: Byte, version: UInt64): Unit
}
```

**相关提交**：`746e7e7`

### 3.3 无锁并发 SkipList

**问题**：仓颉没有 unsafe.Pointer，无法直接实现 Go 版本的 CAS 节点。

**方案**：
1. 使用 `AtomicStorage` 管理连续内存
2. 节点使用 `UInt32 offset` 索引
3. 分段扩容避免预分配开销

**相关提交**：`384dc8a`

### 3.4 Option<WAL> 替代 dummy()

**问题**：disableWAL 时使用 dummy WAL 对象，代码丑陋。

**方案**：
```cangjie
// 旧方案
wal: WAL = dummyWAL()
wal.write(...)  // dummy 什么都不做

// 新方案
wal: ?WAL = None
wal?.write(...)  // None 自动跳过
```

**相关提交**：`b1b81c9`

### 3.5 时间戳处理

**问题**：仓颉无 `~` 按位取反运算符。

**方案**：使用 XOR
```cangjie
// Go 版本
ts := ^uint64(readTs)  // 按位取反

// 仓颉版本
let ts = 0xFFFF_FFFF_FFFF_FFFFu64 ^ readTs
```

---

## 四、Bug 修复记录

### 4.1 SkipList.add 比较方向错误

**现象**：WAL replay 后数据丢失

**原因**：
```cangjie
// 错误：方向反了
if (cmp < 0) { break }  // 应该继续
if (cmp > 0) { continue }  // 应该停止

// 正确
if (cmp < 0) { continue }  // 目标在右边，继续
if (cmp > 0) { break }     // 目标在左边，停止
```

**相关提交**：`19a66c7`

### 4.2 Iterator.seek 时间戳错误

**现象**：seek 找不到正确的 key

**原因**：
```cangjie
// 错误：使用 0 作为时间戳，会被解析为最大
let seekKey = keyWithTs(key, 0)

// 正确：使用 MaxUint64
let seekKey = keyWithTs(key, UInt64.Max)
```

**相关提交**：`e03e37a`

### 4.3 db.get 使用错误 readTs

**现象**：读取不到刚写入的数据

**原因**：
```cangjie
// 错误：使用 version（提交时间戳）
let readTs = version.load()

// 正确：使用 oracle.currentTs()（当前时间戳）
let readTs = oracle.currentTs()
```

**相关提交**：`e03e37a`

### 4.4 Compaction 未持久化

**现象**：close 后重新 open 数据丢失

**原因**：doCompact 只在内存中操作，没有写 SSTable 文件和更新 MANIFEST

**方案**：
1. compactBuildTables() 写 SSTable 文件
2. manifest.saveChanges() 更新 MANIFEST
3. 删除旧 SSTable 文件记录

**相关提交**：`e03e37a`

### 4.5 hashKey 整数溢出

**现象**：大数据量迭代时报错

**方案**：添加 `@OverflowWrapping` 注解
```cangjie
@OverflowWrapping
private func hashKey(key: Array<Byte>): UInt64 {
    var hash: UInt64 = 5381
    for (b in key) {
        hash = ((hash << 5) + hash) + UInt64(b)
    }
    return hash
}
```

**相关提交**：`04bb321`

---

## 五、FFI 优化

### 5.1 memcmp 加速比较

```cangjie
@FastNative
@Frozen
foreign func memcmp(s1: CPointer<Byte>, s2: CPointer<Byte>, n: CSize): CInt

func compareBytes(a: Array<Byte>, b: Array<Byte>): Int {
    let minLen = min(a.size, b.size)
    let result = memcmp(a.ptr, b.ptr, CSize(minLen))
    if (result != 0) { return result.toInt() }
    return a.size.compareTo(b.size)
}
```

**效果**：key 比较性能提升 ~30%

**相关提交**：`e63dce8`

---

## 六、测试经验

### 6.1 @Bench 框架不适合有状态操作

**发现**：仓颉 `@Bench` 对有状态操作（如 DB 写入）误差达 2000-3000%

**方案**：使用独立可执行程序测试
```bash
cjHeapSize=12gb ./target/release/bin/badgercj.examples.txn_perf
```

### 6.2 测试内存限制

**问题**：测试默认 heap 太小，大 MemTable 会 OOM

**方案**：测试时减小 memTableSize
```cangjie
// 生产环境
Config(memTableSize: 64 * 1024 * 1024u64)

// 测试环境
Config(memTableSize: 64 * 1024u64)
```

---

## 七、工具链经验

### 7.1 LSP 报错处理

如果代码看起来正确但 LSP 报错：
- 源码文件：执行 `cjpm build`
- 测试文件：执行 `cjpm test --no-run`

### 7.2 并发测试

```bash
# 并发运行测试
cjpm test -j 16

# 运行指定测试
cjpm test --filter 'ParserTest.testParseRestParameter'
```

---

## 八、完整技术决策索引

| 问题 | 解决方案 | 文件 |
|------|---------|------|
| 仓颉无 unsafe.Pointer | UInt32 offset 索引 Arena | `src/arena/arena.cj` |
| ByteBuffer 不支持随机访问 | Array<Byte> + AtomicUInt32 | `src/arena/arena.cj` |
| 仓颉无 FlatBuffers/Protobuf | 手动实现兼容编码 | `src/table/table_index.cj` |
| 仓颉无 `~` 按位取反 | XOR: `0xFFFF... ^ ts` | `src/db/helpers.cj` |
| Iterator 前缀匹配 bug | 移除 valid() 中冗余 parseKey() | `src/db/iterator.cj` |
| getWithTs O(n) 性能 | 使用 findGe O(log n) | `src/skiplist/skiplist.cj` |
| SkipList 伪 CAS 不安全 | AtomicStorage 真正 CAS | `src/skiplist/atomic_storage.cj` |
| DB 不支持持久化 | close() flush + open() 恢复 | `src/db/db.cj` |
| AtomicStorage 容量不足 | 动态计算 `arenaSize / 32` | `src/db/memtable.cj` |
| MemTableSize 默认太小 | 改为 64MB (与 Go badger 一致) | `src/db/options.cj` |
| hashKey 整数溢出 | `@OverflowWrapping` 注解 | `src/db/iterator.cj` |
| Iterator.seek 找错 key | MaxUint64 而不是 0 作为时间戳 | `src/db/iterator.cj` |
| MemTableIterator 初始化慢 | 延迟迭代：正向 O(1) | `src/db/memtable_iterator.cj` |
| AtomicStorage 预分配太慢 | 分段扩展 + 按需分配 | `src/skiplist/atomic_storage.cj` |
| Node.compareKey 每次创建 Node | 直接访问 Arena buffer | `src/skiplist/skiplist.cj` |
| CRC32C 每次创建查找表 | 全局查找表 | `src/encoding/crc32.cj` |
| LogEntry::encode 逐字节拷贝 | copyTo 批量拷贝 | `src/vlog/entry.cj` |
| Skiplist.add 比较方向错误 | cmp < 0 继续，cmp > 0 停止 | `src/skiplist/skiplist.cj` |
| VLog GC 循环依赖 | VLogGCDB 接口解耦 | `src/vlog/vlog_gc_db.cj` |
| VLog GC 数据丢失风险 | 完整 rewrite + ValuePointer 匹配 | `src/vlog/vlog_manager.cj` |
| lambda 捕获可变变量 | Counter 包装类 | `src/vlog/vlog_gc_test.cj` |
| updateDiscardStats 性能问题 | 移除写入路径调用 | `src/db/badger.cj` |
| Array repeat: 初始化引用类型 | 闭包初始化，否则共享对象 | `src/skiplist/atomic_storage.cj` |
| Option<WAL> 替代 dummy() | wal?.delete() 自动跳过 | `src/db/memtable.cj` |
| db.get 使用错误 readTs | oracle.currentTs() 而非 version.load() | `src/db/badger.cj` |
| oracle 恢复后 ts 未初始化 | oracle.initTs() 设置起始时间戳 | `src/db/oracle.cj` |
| Compaction 未持久化 | 写 SSTable + 更新 MANIFEST | `src/db/compaction.cj` |
| Entry.meta vs userMeta | 分离内部标记和用户标记 | `src/db/entry.cj` |

---

## 九、性能优化效果索引

| 优化项 | 效果 | 相关提交 |
|--------|------|----------|
| AtomicStorage 分段扩展 | 初始化从 12% 降到 <1% | `384dc8a` |
| Arena.putBytes/getBytes copyTo | 批量拷贝替代逐字节 | `d35522c` |
| Node.compareKey 直接访问 Arena | 避免 Node 对象创建 | `d35522c` |
| Skiplist::add 内联优化 | 减少 50% Node 对象创建 | `d35522c` |
| CRC32C 全局查找表 | 从 17% 开销降到 0.04% | `d35522c` |
| LogEntry::encode copyTo | WAL 性能 +92% | `d35522c` |
| Condition 替代轮询 | 大事务延迟 ~100ms → ~1ms | `16ff6e4` |
| WriteRequest 对象池化 | 小事务性能 +10% | `3fdea50` |
| FFI memcmp | key 比较性能 +30% | `e63dce8` |
| 移除 updateDiscardStats | 写入性能提升 2-3x | `b1b81c9` |

---

## 十、参考资源

- 仓颉文档：使用 `cangjie_docs` MCP 工具查询
- Go BadgerDB：`~/Projects/badger` 作为参考实现
- 性能分析：`src/examples/txn_perf/` 独立基准测试