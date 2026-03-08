# 移植go的badger库到仓颉

## 仓颉语言
- 在上下文压缩后，如果没有仓颉语法相关的，需要马上使用`cangjie_mem_list`工具加载所有仓颉语言级记忆
- 在仓颉api和手册可以使用`cangjie_docs`相关工具查找，在`cangjie-mem`没有的直接在文档里查找，不要猜api和语法
- 在提示语法错误时重新使用 `cangjie-mem` 加载语言级记忆
- match 的 case 后不能接`{}`, case后直接写多行列表式而不需要`{}`

## 任务指南
- **不要考虑时间，不要简化算法，不要简化测试，这项目是自己的产品，按最好的来搞**
- 在实现功能总结后，把总结的内容记录到`cangjie-mem`项目级记忆里
- 新功能、新特性一定要写单元测试
- 不要想在项目外创建仓颉单文件测试，非cjpm项目没法导入当前项目
- 新功能需要做好，且有单元测试后提交, 以仓颉单元测试为主
- 测试发现的新问题需要解决，且要添加新用例到仓颉的单元测试里

## 常用命令
```shell
# 编译
cjpm build 
./target/release/bin/main

# 运行所有测试
cjpm test 

# 运行指定测试
cjpm test --show-all-output --filter 'ParserTest.testParseRestParameter'
cjpm test --show-all-output --filter 'ParserTest.*'

# 清理构建缓存 
cjpm clean
```

