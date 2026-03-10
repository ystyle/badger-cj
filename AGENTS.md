# 移植go的badger库到仓颉

## 仓颉语言
- 在上下文压缩后，如果没有仓颉语法相关的，需要马上使用`cangjie_mem_list`工具加载所有仓颉语言级记忆
- 在仓颉api和手册可以使用`cangjie_docs`相关工具查找，在`cangjie-mem`没有的直接在文档里查找，不要猜api和语法
- 在提示语法错误时重新使用 `cangjie-mem` 加载语言级记忆
- match 的 case 后不能接`{}`, case后直接写多行列表式而不需要`{}`

## 任务指南
- **不要考虑时间，不要简化算法，不要简化测试，这项目是自己的产品，按最好的来搞**
- 在实现功能总结后，需要更新`progress-tracking.md`项目进度, 并把值得注意的内容总结的记录到`cangjie-mem`项目级记忆里
- 新功能、新特性一定要写单元测试
- 不要在项目外创建仓颉单文件测试，非cjpm项目没法导入当前项目
- 新功能需要做好，且有单元测试后提交, 以仓颉单元测试为主
- 测试发现的新问题需要解决，且要添加新用例到仓颉的单元测试里
- 测试出现语法问题不通过时，可以使用`cangjie_docs`相关工具在手册或lib std/stdx查找解决方法

## 常用命令
```shell
# 编译
cjpm build 

# 运行
./target/release/bin/main

# 运行所有测试(-j并发测试)
cjpm test -j 16

# 运行指定测试
cjpm test --show-all-output --filter 'ParserTest.testParseRestParameter'
cjpm test --show-all-output --filter 'ParserTest.*'

# 基准测试
cjpm bench

# 清理构建缓存 
cjpm clean
```

### 创建环境变量
>如果找不到cjpm的话，执行以下命令

```shell
source ~/.config/cjvs/store/1.0.4/envsetup.sh
export CANGJIE_STDX_PATH="/home/ystyle/.config/cjvs/stdx/1.0.4/linux_x86_64_llvm/static/stdx"
```

### 项目结构
```shell
❯ tree -L 3
.
├── AGENTS.md                                                  # 项目介绍和开发指南
├── cjpm.lock                                                  # 仓颉包管理锁文件
├── cjpm.toml                                                  # 仓颉包管理配置
├── docs                                                       # 文档目录
│   ├── badger-analysis                                        # BadgerDB 分析文档
│   │   ├── 01-file-formats.md                                 # SSTable/VLog/MANIFEST 文件格式分析
│   │   ├── 02-algorithms.md                                   # LSM-Tree/Compaction 算法分析
│   │   ├── 05-cangjie-api-dependencies.md                     # 仓颉 API 依赖分析
│   │   ├── 05-cangjie-api-dependencies-v1.1.md                # 仓颉 API 依赖分析 v1.1
│   │   └── 06-arena-bytebuffer-analysis.md                    # Arena/ByteBuffer 实现分析
│   ├── phase1-summary.md                                      # Phase 1 总结报告
│   ├── plans                                                  # 设计文档
│   │   ├── 2025-03-07-badger-cj-port-port-design.md           # 总体移植设计
│   │   ├── 2026-03-08-phase3-core-functionality-design.md     # Phase 3 核心功能设计
│   │   ├── 2026-03-08-phase3-core-implementation.md           # Phase 3 实现计划
│   │   └── 2026-03-08-phase4-transaction-design.md            # Phase 4 事务系统设计
│   ├── progress-tracking.md                                   # 项目进度跟踪
│   ├── README.md                                              # 文档索引
│   └── requirements                                           # 需求文档
│       └── badger-cj-requirements.md                          # 功能需求和验收标准
├── log.txt                                                    # 日志文件
├── src                                                        # 源代码目录
│   ├── arena                                                  # Arena 内存分配器
│   │   └── arena.cj                                           # 原子并发内存分配
│   ├── db                                                     # 数据库核心模块
│   │   ├── db.cj                                              # DB 主类
│   │   ├── memtable.cj                                        # MemTable 实现
│   │   ├── memtable_iterator.cj                               # MemTable 迭代器
│   │   ├── levels.cj                                          # LevelsController (LSM 层管理)
│   │   ├── level_handler.cj                                   # LevelHandler (L0/L1+ 查找)
│   │   ├── wal.cj                                             # Write-Ahead Log
│   │   ├── oracle.cj                                          # 全局时间戳管理器
│   │   ├── watermark.cj                                       # 完成标记追踪
│   │   ├── transaction.cj                                     # 完整事务实现
│   │   ├── iterator.cj                                        # 一致性范围扫描
│   │   ├── snapshot.cj                                        # 一致性快照读
│   │   ├── helpers.cj                                         # 辅助函数 (keyWithTs/parseTs 等)
│   │   └── compaction.cj                                      # Compaction 逻辑
│   ├── encoding                                               # 编码模块
│   │   ├── crc32.cj                                           # CRC32-C 校验和
│   │   └── varint.cj                                          # Varint 编解码
│   ├── manifest                                               # MANIFEST 模块
│   │   ├── manifest.cj                                        # 元数据管理
│   │   └── manifest_change.cj                                 # Manifest 变更记录
│   ├── skiplist                                               # Skiplist 模块
│   │   ├── skiplist.cj                                        # 跳表实现
│   │   └── node.cj                                            # 跳表节点
│   ├── table                                                  # SSTable 模块
│   │   ├── builder.cj                                         # SSTable 构建器
│   │   ├── table.cj                                           # SSTable 读取器
│   │   ├── block_builder.cj                                   # Block 构建器
│   │   ├── block_iterator.cj                                  # Block 迭代器
│   │   ├── table_index.cj                                     # TableIndex (FlatBuffers)
│   │   └── types.cj                                           # ValueStruct/Meta 定义
│   └── vlog                                                   # Value Log 模块
│       ├── entry.cj                                           # LogEntry 编解码
│       ├── vlog.cj                                            # ValueLog 实现
│       └── vlog_manager.cj                                    # VLog 文件管理
```
