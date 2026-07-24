# 序列化库替换计划 (FlatBuffers + Protobuf)

> **Goal:** 将 badger-cj 的手写编码替换为 `flatbuffers-cj` 和 `protobuf4cj` 标准库，实现与 Go badger 的二进制兼容。

**Architecture:**
- `flatbuffers-cj` 替换 `table_index.cj`/`builder.cj` 中的手写 SSTable 索引编码
- `protobuf4cj` + `protoc-gen-cj` 生成 `badgerpb4.proto` 的仓颉代码，替换 `manifest_change.cj`、`backup.cj` 中的手动序列化
- 新增 `src/pb/` 放置生成的 `.pb.cj` 代码，新增 `src/fb/` 放置 FlatBuffers schema 和生成的代码

**Tech Stack:** cjc 1.1.0, flatbuffers-cj, protobuf4cj (protobuf + protoc-gen-cj)

---

### Task 1: 添加依赖并搭建骨架

**Files:**
- Modify: `cjpm.toml`
- Create: `src/pb/` 目录
- Create: `src/fb/` 目录

**Step 1: 更新 cjpm.toml 添加依赖**

```toml
[dependencies]
"snappy" = "1.0.0"
"flatbuffers" = { path = "../flatbuffers-cj/src/protobuf" }
"protobuf" = { path = "../protobuf4cj/src/protobuf" }
```

注意：flatbuffers-cj 需要确认正确的包路径（`src/protobuf` 目录下是 package `flatbuffers`）。
protobuf4cj 的 package 名是 `protobuf`。

**Step 2: 创建目录结构**

```bash
mkdir -p src/pb src/fb
```

**Step 3: 编译验证**

```bash
./cjpmw.sh build -j 16
```

预期：编译通过，323 个测试全部通过（尚未修改任何业务代码）。

---

### Task 2: 定义 FlatBuffers schema 并替换 TableIndex

**Files:**
- Create: `src/fb/table_index.fbs` — FlatBuffers schema 文件（参考 Go badger 的 `fb/tableindex.fbs`）
- Rewrite: `src/table/table_index.cj` — 用 flatbuffers Table 读取替代手动 decode
- Modify: `src/table/builder.cj:198-296` — `buildTableIndex()` 用 flatbuffers Builder 替代手动编码
- Modify: `src/table/table.cj` — 适配新的 TableIndex 接口
- Modify: `src/table/types.cj` — 确保 BlockOffset 与 flatbuffers 兼容
- Test: `src/table/builder_test.cj`
- Test: `src/table/integration_test.cj`

**Step 1: 编写 TableIndex 的 FlatBuffers schema**

`syntax = "flatbuffers"` 格式，对应 Go badger 的 `fb/tableindex.fbs`：

```fbs
table BlockOffset {
  key: [ubyte] (required);
  offset: uint;
  len: uint;
  compression: byte = 0;
}

table TableIndex {
  offsets: [BlockOffset];
  bloom_filter: [ubyte];
  max_version: ulong;
  key_count: uint;
  uncompressed_size: uint;
  on_disk_size: uint;
  stale_data_size: uint;
}

root_type TableIndex;
```

Note: Go badger 的索引不含 `tableSmallest/tableBiggest` — 它们来自 data block 的第一/最后一个 key。当前 Cangjie 版本自带的这两个字段是额外扩展，保持不变需要考虑额外的编码方式。

**Step 2: 生成 FlatBuffers 编码代码**

flatbuffers-cj 的 `@FlatBuffer` 宏可以生成编码/解码代码，或者手写 Builder 调用。

参考 flatbuffers-cj 的使用方式，手写 Builder 构建和 Table 读取。

**Step 3: 重写 `table_index.cj`**

- `decodeFromData()` — 外层包装器解析（CRC32 校验、索引大小）不变，只改内部 `decode()` 
- `decode()` — 用 flatbuffers `Table` 的 getter 替代手写逐字节解析
- 保留 `seekBlock()` 方法

**Step 4: 重写 `builder.cj:buildTableIndex()`**

- 用 flatbuffers `Builder` 构建 TableIndex
- 替换手写的逐字节小端序写入

**Step 5: 编译 + 测试**

```bash
./cjpmw.sh build -j 16
./cjpmw.sh test --no-progress --filter 'TableBuilder*'
./cjpmw.sh test --no-progress --filter 'TableIntegration*'
```

**Step 6: 提交**

```bash
git add src/fb/ src/table/table_index.cj src/table/builder.cj
git commit -m "feat: 用 flatbuffers-cj 替换手写 TableIndex 编码"
```

---

### Task 3: 用 protobuf4cj 生成 badgerpb4 代码

**Files:**
- Create: `src/pb/badgerpb4.proto` — 从 Go badger 拷贝（去掉 `go_package` 等仓颉不需要的选项）
- Create: `src/pb/badgerpb4.pb.cj` — 用 `protoc-gen-cj` 生成（或手写）
- Create: `src/pb/badgerpb4_test.cj` — 验证编码/解码一致性

**Step 1: 编写 proto 文件**

```protobuf
syntax = "proto3";
package badgerpb4;

message KV {
  bytes key = 1;
  bytes value = 2;
  bytes user_meta = 3;
  uint64 version = 4;
  uint64 expires_at = 5;
  bytes meta = 6;
  uint32 stream_id = 10;
  bool stream_done = 11;
}

message KVList {
  repeated KV kv = 1;
  uint64 alloc_ref = 10;
}

message ManifestChangeSet {
  repeated ManifestChange changes = 1;
}

message ManifestChange {
  uint64 Id = 1;
  enum Operation {
    CREATE = 0;
    DELETE = 1;
  }
  Operation Op = 2;
  uint32 Level = 3;
  uint64 key_id = 4;
  EncryptionAlgo encryption_algo = 5;
  uint32 compression = 6;
}

enum EncryptionAlgo {
  aes = 0;
}

message Checksum {
  enum Algorithm {
    CRC32C = 0;
    XXHash64 = 1;
  }
  Algorithm algo = 1;
  uint64 sum = 2;
}

message DataKey {
  uint64 key_id = 1;
  bytes data = 2;
  bytes iv = 3;
  int64 created_at = 4;
}

message Match {
  bytes prefix = 1;
  string ignore_bytes = 2;
}
```

**Step 2: 用 protoc-gen-cj 生成代码**

```bash
protoc --cj_out=src/pb/ src/pb/badgerpb4.proto
```

生成 `badgerpb4.pb.cj` 到 `src/pb/`，包名为 `package badgerpb4`。

如果当前环境没有 protoc，可以直接提交生成的 `.pb.cj` 源码。

**Step 3: 编译验证**

```bash
./cjpmw.sh build -j 16
```

预期：项目结构需添加 `src/pb/` 到编译路径，或确认 cjpm.toml 的 include 覆盖了 `src/pb/`。

**Step 4: 提交**

```bash
git add src/pb/
git commit -m "feat: 添加 protobuf4cj 生成的 badgerpb4 代码"
```

---

### Task 4: 替换 ManifestChange 为 protobuf4cj

**Files:**
- Rewrite: `src/manifest/manifest_change.cj` — 用 `ManifestChangeSet`/`ManifestChange` 生成的 proto 类替换
- Modify: `src/manifest/manifest.cj` — 适配新的 ManifestChangeSet API
- Modify: `src/manifest/manifest_file.cj` — 适配序列化/反序列化
- Test: `src/manifest/manifest_test.cj`
- Test: `src/manifest/manifest_file_test.cj`

**Step 1: 分析当前编码兼容性**

当前 `manifest_change.cj` 已经是手动 protobuf 兼容编码（field tag + varint wire format）。
用 protobuf4cj 生成的 `ManifestChangeSet` 后，序列化结果应该是**二进制完全一致**的。

**Step 2: 替换实现**

```cangjie
// 旧代码
let change = ManifestChange(id, op, level: level, keyID: keyID)
let encoded = change.encode()

// 新代码
let change = ManifestChange(Id: id, Op: op, Level: level, key_id: keyID)
let encoded = change.pack()
```

**Step 3: 运行测试验证兼容性**

用 protobuf4cj 序列化的结果与 Go badger 的 proto 序列化结果二进制一致。

```bash
./cjpmw.sh test --no-progress --filter 'Manifest*'
```

**Step 4: 提交**

```bash
git add src/manifest/manifest_change.cj src/manifest/manifest.cj src/manifest/manifest_file.cj
git commit -m "feat: 用 protobuf4cj 替换 ManifestChange 编码"
```

---

### Task 5: 替换 Backup 格式为 protobuf4cj

**Files:**
- Rewrite: `src/db/backup.cj` — `BackupWriter`/`BackupReader` 用 `KVList`/`KV` protobuf 类
- Modify: `src/db/badger.cj` — 适配新的 backup API
- Test: `src/db/backup_test.cj`

**Step 1: 分析当前格式差异**

当前 backup 使用自定义格式：
```
Magic(5B) + Version(4B) + Flags(4B) + [BlockSize(8B) + BlockData]...
```

Go badger 使用 proto 格式：
```
KVList 序列化后按 length-delimited 写入
```

替换后备份文件格式完全对齐 Go badger。

**Step 2: 重写 BackupWriter**

```cangjie
public func flush(): Unit {
    let kvList = KVList()
    // ... fill kvList.kv
    let packed = kvList.pack()
    // write packed bytes with length prefix
}
```

**Step 3: 重写 BackupReader**

```cangjie
public func readBlock(): Unit {
    let packed = readBytes(len)
    let kvList = KVList.fromBytes(packed)
    // ... process kv
}
```

**Step 4: 运行测试**

```bash
./cjpmw.sh test --no-progress --filter 'Backup*'
```

**Step 5: 提交**

```bash
git add src/db/backup.cj
git commit -m "feat: 用 protobuf4cj 替换 Backup 格式，对齐 Go 兼容"
```

---

### Task 6: 版本号升级至 2.0.0

**Files:**
- Modify: `cjpm.toml` — version `1.6.0` → `2.0.0`
- Modify: `docs/progress-tracking.md` — 更新版本号

**Step 1: 更新版本号**

```bash
sed -i 's/version = "1.6.0"/version = "2.0.0"/' cjpm.toml
```

**Step 2: 提交**

```bash
git add cjpm.toml
git commit -m "chore: 升版至 2.0.0 (flatbuffers + protobuf 序列化库替换)"
```

---

### 注意点

1. **TableIndex 中的 tableSmallest/tableBiggest** — 当前 Cangjie 版本在索引中额外存储了这两个字段，Go 版本没有。替换为 flatbuffers 时需要决定是保留扩展（加在 schema 末尾）还是去掉（从 data block 首尾 key 获取）。

2. **Backup 格式不向前兼容** — 替换后用新格式备份的文件不能被旧版本 badger-cj 恢复，反之亦然。文档中需注明。

3. **protoc 生成环境** — 生成的 `.pb.cj` 源码直接提交，仓库使用者无需安装 protoc。建议在 `Makefile` 或脚本中记录生成命令。

4. **flatbuffers-cj 的宏支持** — 如果 `@FlatBuffer` 宏可以自动生成编码/解码代码，优先使用；否则手写 Builder/Table。

5. **flatbuffers-cj 和 protobuf4cj 的依赖路径** — 当前两个项目在本地同级目录，`cjpm.toml` 用 `path =` 引用。将来可以改为 git 依赖。
