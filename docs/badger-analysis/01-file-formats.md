# BadgerDB 文件格式深度分析

本文档详细分析 BadgerDB v4 的文件格式，为仓颉移植提供字节级的兼容性参考。

## 概述

BadgerDB 使用三种主要文件类型：
1. **SSTable (.sst)** - Sorted String Table，存储有序的键值对
2. **Value Log (.vlog)** - 分离存储大值，减少写放大
3. **MANIFEST** - 元数据文件，记录数据库状态

## 1. SSTable 文件格式

### 1.1 整体结构

```
┌──────────────────────────────────────────────────────┐
│                   SSTable 文件                       │
├──────────────────────────────────────────────────────┤
│  Block 1                                             │
│  Block 2                                             │
│  Block 3                                             │
│  ...                                                 │
│  Block N                                             │
├──────────────────────────────────────────────────────┤
│  Table Index (FlatBuffers)                          │
│  Index Size (4 bytes, uint32, little-endian)        │
├──────────────────────────────────────────────────────┤
│  Checksum (CRC32, 4 bytes)                          │
│  Checksum Size (4 bytes, uint32, little-endian)     │
└──────────────────────────────────────────────────────┘
```

### 1.2 Block 结构

每个 Block 的内部布局：

```
┌─────────────────────────────────────────────────────┐
│                   Block 内部结构                     │
├─────────────────────────────────────────────────────┤
│  Entry 1                                            │
│  Entry 2                                            │
│  ...                                                │
│  Entry N                                            │
├─────────────────────────────────────────────────────┤
│  Entry Offsets (uint32 array, 4 bytes each)        │
│  Num Entries (4 bytes, uint32, little-endian)      │
├─────────────────────────────────────────────────────┤
│  Checksum (CRC32, 4 bytes)                          │
│  Checksum Size (4 bytes, uint32, little-endian)    │
└─────────────────────────────────────────────────────┘
```

**关键点：**
- Entry Offsets 数组用于二分查找
- Checksum 验证数据完整性
- Little-endian 字节序

### 1.3 Entry 结构

每个 Entry 的格式（使用前缀压缩）：

```
Entry Layout:
┌──────────┬──────────────┬───────────┐
│ Header   │ Diff Key     │ Value     │
│ (4 bytes)│ (var bytes)  │ (var)     │
└──────────┴──────────────┴───────────┘

Header (4 bytes):
┌──────────────┬──────────────┐
│ Overlap (2B) │ Diff Len (2B)│
│ uint16 LE    │ uint16 LE    │
└──────────────┴──────────────┘
```

**前缀压缩原理：**
- `Overlap`：与 Block Base Key 的公共前缀长度
- `Diff Len`：差异部分的长度
- `Diff Key`：差异部分的字节数据

**示例：**
```
Base Key: "apple"
Key 2:    "application"

Header: Overlap=3 (共享 "app"), Diff=8 ("lication")
实际存储: [0x03, 0x00, 0x08, 0x00] + "lication"
```

### 1.4 Value 编码

Value 使用 `ValueStruct` 编码：

```
ValueStruct Layout:
┌──────┬───────────┬───────────┬────────────┐
│ Meta │ UserMeta  │ ExpiresAt │ Value/VP   │
│ 1B   │ 1B        │ 8B (opt)  │ (var)      │
└──────┴───────────┴───────────┴────────────┘

Meta 字段位标志:
- bitDelete (0x01): 标记删除
- bitValuePointer (0x02): 值存储在 Value Log
- bitDiscardEarlierVersions (0x04): 丢弃旧版本
- bitMergeEntry (0x08): 合并条目
- bitTxn (0x40): 事务条目
- bitFinTxn (0x80): 事务结束标记
```

**两种存储模式：**

1. **内联值（小值）：**
   ```
   Meta = 0x00
   后面直接跟 Value 字节数据
   ```

2. **ValuePointer（大值）：**
   ```
   Meta = 0x02 (bitValuePointer)
   后面跟 ValuePointer 结构：
   ┌─────────┬──────────┬──────────┐
   │ Fid (4B)│ Len (4B) │ Offset(4B)│
   │ uint32  │ uint32   │ uint32   │
   └─────────┴──────────┴──────────┘
   ```

### 1.5 Table Index 结构

Table Index 使用 FlatBuffers 编码：

```
FlatBuffers Schema (fb/flatbuffer.fbs):

table TableIndex {
  offsets: [BlockOffset];      // Block 偏移量数组
  bloom_filter: [ubyte];       // Bloom Filter 位图
  max_version: uint64;         // 最大版本号
  key_count: uint32;           // 键数量
  uncompressed_size: uint32;   // 未压缩大小
  on_disk_size: uint32;        // 磁盘大小
  stale_data_size: uint32;     // 陈旧数据大小
}

table BlockOffset {
  key: [ubyte];    // 该 Block 的起始键
  offset: uint;    // Block 在文件中的偏移量
  len: uint;       // Block 长度
}
```

**FlatBuffers 二进制格式（简化版）：**

```
Table Index 序列化示例:
┌─────────────────────────────────────┐
│ Root Table Offset (4B, uint32 LE)   │
├─────────────────────────────────────┤
│ VTable                              │
│ - VTable Size (4B)                  │
│ - Table Size (4B)                   │
│ - Field Offsets (4B each)           │
├─────────────────────────────────────┤
│ Table Data                          │
│ - offsets offset (4B)               │
│ - bloom_filter offset (4B)          │
│ - max_version (8B)                  │
│ - key_count (4B)                    │
│ - ...                               │
├─────────────────────────────────────┤
│ BlockOffset Vector                  │
│ - Count (4B)                        │
│ - BlockOffset 1                     │
│ - BlockOffset 2                     │
│ - ...                               │
├─────────────────────────────────────┤
│ Bloom Filter Data                   │
│ - Filter Size (4B)                  │
│ - Filter Bytes                      │
└─────────────────────────────────────┘
```

### 1.6 Bloom Filter 格式

```
Bloom Filter Layout:
┌──────────────────┬─────────────────┐
│ Filter Bytes     │ Num Hash Functions│
│ (var bytes)      │ (4B, uint32 LE)  │
└──────────────────┴─────────────────┘

算法：
1. 对 Key 计算 MurmurHash3
2. 根据 false positive rate 确定位图大小
3. 使用多个哈希函数设置位
```

### 1.7 Checksum 计算

```
Checksum 算法: CRC32 (Castagnoli)

计算范围:
- Block Checksum: Block 数据（不包含 Checksum 字段本身）
- Index Checksum: 整个 Index 数据（不包含 Checksum 字段）

实现：
hash := crc32.New(crc32.MakeTable(crc32.Castagnoli))
hash.Write(data)
checksum := hash.Sum32()  // 4 bytes, little-endian
```

## 2. Value Log 文件格式

### 2.1 整体结构

Value Log 是一个追加写入的日志文件：

```
┌──────────────────────────────────────────────┐
│                Value Log 文件                │
├──────────────────────────────────────────────┤
│  Header (20 bytes, 仅加密时存在)             │
├──────────────────────────────────────────────┤
│  Entry 1                                     │
│  Entry 2                                     │
│  Entry 3                                     │
│  ...                                         │
│  Entry N                                     │
└──────────────────────────────────────────────┘
```

### 2.2 Value Log Header（加密时）

```
Header Layout (20 bytes):
┌────────────────┬──────────────────┐
│ KeyID (8B)     │ BaseIV (12B)     │
│ uint64 LE      │ bytes            │
└────────────────┴──────────────────┘

用途：
- KeyID: 加密密钥标识
- BaseIV: 初始向量基础值
```

### 2.3 Value Log Entry 结构

```
Entry Layout:
┌─────────┬──────────┬───────┬───────┬──────┬─────┬───────┬────────┐
│ CRC32   │ Header   │ kLen  │ vLen  │ Meta │ Key │ Value │ UserMeta│
│ (4B)    │ (1B)     │ (2B)  │ (2B)  │ (1B) │ var │ var   │ (opt)  │
└─────────┴──────────┴───────┴───────┴──────┴─────┴───────┴────────┘

Header 字段（1 byte）:
- bit 0-5: hlen (header length, 通常为 header + kLen + vLen + meta = 6)
- bit 6: hasExpiresAt (是否有过期时间)
- bit 7: hasUserMeta (是否有用户元数据)

完整字段顺序：
1. Header (1 byte)
2. kLen (2 bytes, uint16 LE)
3. vLen (2 bytes, uint16 LE)
4. meta (1 byte)
5. userMeta (1 byte, optional)
6. expiresAt (8 bytes, uint64 LE, optional)
7. Key (kLen bytes)
8. Value (vLen bytes)
9. CRC32 (4 bytes, uint32 LE)
```

**CRC32 计算范围：**
从 Header 开始到 Value 结束（不包含 CRC32 字段本身）

### 2.4 示例：写入一个 Entry

```go
// Go 代码示例
entry := &Entry{
    Key:      []byte("mykey"),
    Value:    []byte("myvalue"),
    Meta:     0,
    UserMeta: []byte{0x01},
}

// 序列化
header := byte(6 | 0x80)  // hlen=6, hasUserMeta=true
kLen := uint16(5)         // "mykey"
vLen := uint16(7)         // "myvalue"

buf := []byte{
    header,
    byte(kLen), byte(kLen >> 8),      // little-endian
    byte(vLen), byte(vLen >> 8),
    0x00,                              // meta
    0x01,                              // userMeta
}
buf = append(buf, entry.Key...)
buf = append(buf, entry.Value...)

// 计算 CRC32
hash := crc32.New(crc32.MakeTable(crc32.Castagnoli))
hash.Write(buf)
crc := hash.Sum32()
buf = append(buf, byte(crc), byte(crc>>8), byte(crc>>16), byte(crc>>24))
```

### 2.5 Value Log 文件命名

```
文件名格式: <fid>.vlog
示例: 000001.vlog, 000002.vlog

fid: 文件 ID，uint32，递增
```

## 3. MANIFEST 文件格式

### 3.1 整体结构

MANIFEST 是一个追加写入的日志文件：

```
┌──────────────────────────────────────────┐
│            MANIFEST 文件                 │
├──────────────────────────────────────────┤
│  Magic Number (4 bytes, 0xDB4778)       │
│  Version (4 bytes, uint32 LE)           │
├──────────────────────────────────────────┤
│  ChangeSet 1 (Protocol Buffers)         │
│  ChangeSet 2                            │
│  ChangeSet 3                            │
│  ...                                    │
└──────────────────────────────────────────┘
```

### 3.2 ManifestChangeSet 结构

使用 Protocol Buffers 编码：

```protobuf
message ManifestChangeSet {
  repeated ManifestChange changes = 1;
}

message ManifestChange {
  uint64 Id = 1;            // Table ID
  enum Operation {
    CREATE = 0;
    DELETE = 1;
  }
  Operation Op   = 2;
  uint32 Level   = 3;       // LSM Level (0-6)
  uint64 key_id  = 4;       // Encryption Key ID
  EncryptionAlgo encryption_algo = 5;
  uint32 compression = 6;   // Compression type
}
```

### 3.3 Protocol Buffers 编码规则

**Varint 编码：**
```
每个字节：
- bit 7: 是否有后续字节 (1=继续, 0=结束)
- bit 0-6: 7 位数据

示例：
数字 1:   [0x01]
数字 300: [0xAC, 0x02]
  300 = 0x2AC = (0x2 << 7) | 0x2C
  编码: [1<<7 | 0x2C, 0x02] = [0xAC, 0x02]
```

**Field 编码：**
```
Tag = (field_number << 3) | wire_type

Wire Types:
- 0: Varint
- 1: 64-bit
- 2: Length-delimited
- 5: 32-bit

示例：
field 1, varint: tag = (1 << 3) | 0 = 0x08
field 2, varint: tag = (2 << 3) | 0 = 0x10
field 3, varint: tag = (3 << 3) | 0 = 0x18
```

### 3.4 ManifestChange 序列化示例

```go
// Go 代码
change := &pb.ManifestChange{
    Id:         12345,
    Op:         pb.ManifestChange_CREATE,  // 0
    Level:      2,
    KeyId:      0,
    Compression: 1,  // Snappy
}

// 手动序列化（不使用 protobuf 库）
buf := []byte{
    // Field 1 (Id): tag=0x08, varint
    0x08,
    encodeVarint(12345),  // [0xB9, 0x60]
    
    // Field 2 (Op): tag=0x10, varint
    0x10,
    0x00,  // CREATE = 0
    
    // Field 3 (Level): tag=0x18, varint
    0x18,
    0x02,  // Level = 2
    
    // Field 6 (Compression): tag=0x30, varint
    0x30,
    0x01,  // Snappy = 1
}

// ChangeSet 包装
changeSet := []byte{
    // Field 1 (changes): tag=0x0A, length-delimited
    0x0A,
    byte(len(buf)),  // length prefix
}
changeSet = append(changeSet, buf...)
```

### 3.5 MANIFEST 文件命名

```
文件名: MANIFEST
备份文件: MANIFEST-<timestamp>

示例:
MANIFEST
MANIFEST-20250307-120000
```

## 4. 文件格式兼容性检查清单

### 4.1 SSTable 兼容性

- [ ] Block 布局正确（Entry + Offsets + Checksum）
- [ ] Entry Header 使用 little-endian
- [ ] 前缀压缩算法一致
- [ ] ValueStruct 编码正确（Meta + UserMeta + Value/VP）
- [ ] CRC32 使用 Castagnoli 表
- [ ] FlatBuffers Index 格式正确
- [ ] Bloom Filter 格式一致

### 4.2 Value Log 兼容性

- [ ] Entry Header 字段顺序正确
- [ ] Varint 编码正确
- [ ] CRC32 计算范围正确
- [ ] Little-endian 字节序
- [ ] 文件命名格式一致

### 4.3 MANIFEST 兼容性

- [ ] Magic Number 正确 (0xDB4778)
- [ ] Protocol Buffers 编码正确
- [ ] Varint 编码符合规范
- [ ] Field tags 正确

## 5. 实现建议

### 5.1 优先级

1. **Phase 1**: 实现基础 Varint 和 CRC32
  - `CRC32`: 参考`/home/ystyle/Projects/Cangjie/zip-cj/src/crc32.cj`
2. **Phase 2**: 实现 SSTable 读写
3. **Phase 3**: 实现 Value Log 读写
4. **Phase 4**: 实现 MANIFEST 管理

### 5.2 验证方法

```cangjie
// 仓颉代码示例：验证兼容性
func verifyCompatibility() {
    // 1. 用 Go 版本写入测试数据
    // 2. 用仓颉版本读取
    // 3. 对比字节序列
    
    let goData = readGoBadgerFile("test.sst")
    let cjData = readCJBadgerFile("test.sst")
    
    assert(goData == cjData)  // 字节级一致
}
```

### 5.3 调试技巧

1. 使用 `hexdump -C file.sst` 查看二进制
2. 对比 Go 和仓颉版本的输出
3. 逐字段验证序列化结果
4. 使用单元测试覆盖边界情况

## 6. 参考资料

**BadgerDB 源码：**
- `table/builder.go`: SSTable 写入
- `table/table.go`: SSTable 读取
- `value.go`: Value Log 实现
- `manifest.go`: MANIFEST 管理

**协议规范：**
- [Protocol Buffers Encoding](https://developers.google.com/protocol-buffers/docs/encoding)
- [FlatBuffers](https://google.github.io/flatbuffers/)

**相关论文：**
- [WiscKey: Separating Keys from Values in SSD-conscious Storage](https://www.usenix.org/system/files/conference/fast16/fast16-papers-lu.pdf)


## 2.0 的文件布局与格式基线

2.0 保持 SSTable/MANIFEST/LogEntry 的**字节语法**与 v1.6.x 一致（可读旧库），但文件布局与
物理大小语义有变化：

| 文件 | v1.6.x | 2.0 |
|---|---|---|
| WAL | 单文件 fid.mem，无预分配 | **多段** fid.mem / fid.mem.N；mmap 稀疏预分配（2×MemTableSize），段满换段、封口截断；崩溃恢复按段扫描、按条目边界截断残尾 |
| VLog | 单文件按需增长 | 段内**固定映射 + 稀疏预分配**（vlogFileSize，默认 1GB），段满换段；遍历/GC 用流式按条读，不再整段驻留 |
| SSTable | 整表读入 GC 堆 | **只读映射**（mmapSSTable 默认开）；索引只读文件尾部三段，堆内表示 = 索引原始字节 + 每块 4B 位置表，块 key 按需解析（lazy index） |
| 目录 | 无格式声明 | **新增 FORMAT**：format=1 + features=（缺失视为 v1.6.x，首次打开补写；更高格式/未知 feature 拒绝打开） |

格式号语义：format=1 = 当前字节语法；后续引入改变字节语义的能力（如加密、merge 标记版本化）
时递增，并在 features 里声明。**不把版本写进 MANIFEST**：ManifestChangeSet 解码器遇未知顶层
tag 不推进 offset，旧版本读到新 MANIFEST 会死循环。
