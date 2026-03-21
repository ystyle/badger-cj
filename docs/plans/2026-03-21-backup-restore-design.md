# Backup/Restore 设计文档

**日期：** 2026-03-21  
**状态：** 已批准

---

## 概述

实现 Badger-cj 的数据备份和恢复功能，支持全量和增量备份。

---

## 文件格式

### Header (12 bytes)

| 字段 | 大小 | 说明 |
|------|------|------|
| Magic | 4 bytes | "BADCJ" 标识 |
| Version | 4 bytes | 格式版本 (当前 1) |
| Flags | 4 bytes | 保留扩展 |

### KVList Block (repeated)

| 字段 | 大小 | 说明 |
|------|------|------|
| Size | 8 bytes | Block 大小（不含 Size 字段） |
| Count | 4 bytes | KV 数量 |
| MaxVersion | 8 bytes | 本 block 最大版本 |
| KV entries | 变长 | 重复 Count 次 |

### KV Entry 格式

| 字段 | 大小 | 说明 |
|------|------|------|
| KeyLen | 4 bytes | Key 长度 |
| Key | KeyLen bytes | Key 数据 |
| ValueLen | 4 bytes | Value 长度 |
| Value | ValueLen bytes | Value 数据 |
| UserMeta | 1 byte | 用户元数据 |
| Version | 8 bytes | 版本号 |
| ExpiresAt | 8 bytes | 过期时间 |
| Meta | 1 byte | 内部元数据 |

---

## API 设计

```cangjie
// Badger 扩展方法
public func Backup(writer: OutputStream, since!: UInt64 = 0): UInt64
public func Restore(reader: InputStream): Unit

// Stream 扩展方法
public func Backup(writer: OutputStream, since: UInt64): UInt64
```

### 参数说明

- `writer`: 输出流，支持文件、网络等
- `since`: 增量备份起始版本，默认 0 表示全量备份
- **返回值**: 备份的最大版本号，可用于下次增量备份

---

## 实现细节

### Backup 流程

1. 写入 Header
2. 使用 Stream API 遍历数据
3. `keyToList` 回调过滤并收集 KV
4. `send` 回调批量写入 KVList Block
5. 返回 maxVersion

### Restore 流程

1. 读取并验证 Header
2. 循环读取 KVList Block
3. 批量写入数据库 (batchSet)
4. 更新 oracle.nextTxnTs
5. 完成

### 批量写入策略

- 每 100MB 刷新一次（flushThreshold）
- 复用现有的 batchSet/batchSetAsync

---

## 文件结构

```
src/db/backup.cj        - Backup 实现
src/db/restore.cj       - Restore 实现 (可合并到 backup.cj)
src/db/backup_test.cj   - 测试用例
```

---

## 测试用例

1. `testBackupRestore` - 全量备份恢复
2. `testIncrementalBackup` - 增量备份
3. `testBackupWithTTL` - 带 TTL 数据
4. `testBackupWithDelete` - 已删除数据不备份
5. `testRestoreToEmptyDB` - 恢复到空数据库