# 模型占用信息 · SketchUp 插件

版本：1.0.0（开发版）

[下载插件安装包（RBZ）](https://github.com/yangcen0411-alt/model-size-info/raw/refs/heads/main/downloads/model_size_info_v1.0.0.rbz) · [下载源码包](https://github.com/yangcen0411-alt/model-size-info/raw/refs/heads/main/downloads/model_size_info_v1.0.0_source.zip)

这是一个类似“图元信息”的独立浮动面板：选择群组或组件后，显示该组件定义单独保存为 SKP 文件的实际字节数，并换算为 KB、MB。没有选择时，显示整个模型上次保存的文件大小。可点击“测量当前模型”，通过临时副本测量包含未保存修改的当前版本。

## 安装和打开

适用于 SketchUp 2022 及更新的桌面版；不适用于网页版。采用这些版本公开的 Ruby API 开发，尚未完成 SketchUp 界面内的实际验证。

1. 下载 `model_size_info_v1.0.0.rbz`，保留 `.rbz` 后缀，无需解压。
2. 在 SketchUp 中打开 **扩展程序管理器**，点击 **安装扩展程序**，选择这个文件。不同版本可能将管理器放在“窗口”或“扩展程序”菜单中。
3. 打开 **扩展程序 → 模型占用信息**。也可以在建模区域右键菜单中打开“模型占用信息”。
4. 选中一个群组或组件，等待片刻即可查看大小。

这是未经过 Extension Warehouse 签名的开发版。如果 SketchUp 要求批准该扩展，请在管理器中手动批准此插件。无需更改全部扩展的加载策略。

## 如何使用

| 操作 | 显示内容 |
| --- | --- |
| 选择一个群组或组件 | 它的独立 SKP 文件大小、实例名称、类型、当前层内部图元数、模型中的实例数 |
| 选择同一组件的多个实例 | 相同定义只测量并计算一次 |
| 多选不同组件 | 各定义的独立文件大小，按体积从大到小排列，并显示合计 |
| 点击空白处取消选择 | 整个模型的上次保存文件大小 |
| 切换“整个模型” | 保持当前选择，同时查看模型大小 |
| 点击“测量当前模型” | 临时保存当前模型副本，测量包含未保存修改的大小 |
| 取消“自动测量选择” | 选择后只更新属性，需要点击按钮才导出测量 |
| 点击右上角刷新 | 清除缓存并刷新；小范围选择在自动模式下会重新测量 |

自动模式下，选择稳定约 0.6 秒后开始测量，最多自动测量 3 个不同定义。选择更多不同定义时，点击“测量选中定义”开始。大型组件的单次副本保存由 SketchUp 同步执行，可能需要短暂等待；“停止后续测量”取消尚未开始的任务。

## 大小的含义

- **群组和组件**：通过官方 `ComponentDefinition#save_copy` 将定义临时保存成当前 SketchUp 格式的 SKP，再读取实际文件字节数。包含定义中的几何、嵌套对象、材质和相关数据。实例外层的材质、缩放等覆盖不在组件定义中，因此不计入该数值。
- **同一组件多次复制**：实例共享组件定义，所以不会按实例数量直接乘算大小。
- **不同定义合计**：每个定义独立导出的文件大小之和。不同文件中可能重复包含共享的嵌套组件、材质及文件头，所以它不是“合并后精确体积”，也不表示删除这些对象后原模型会减小多少。
- **整个模型**：默认读取原 SKP 在磁盘上的大小，明确标记未保存修改；点击按钮后通过 `Model#save_copy` 测量当前模型副本。不会覆盖原 SKP。
- **散线、面和图片等**：没有独立的组件 SKP 文件。请先手动创建群组或组件再测量；混合选择时只显示可测定义明细，不显示误导性的完整合计。
- **单位**：1 KB = 1024 字节，1 MB = 1024 KB。显示的是文件体积，与内存占用及模型的长宽高不同。

临时副本在测量结束或失败后自动清理。插件不会自动清理模型、重组几何、让组件唯一化、覆盖原文件或更改组件源路径。SketchUp 官方文档记录了 2027 以前保存组件副本可能更新定义 GUID 的问题；依赖 GUID 做外部追踪的工作流应留意这一宿主程序行为。

面板是可移动、可缩放的独立窗口，不属于默认托盘中的原生“图元信息”面板。

## 验证情况

已使用 SketchUp 2026 随附的 Ruby 3.2.2 通过源代码语法检查和 42 项隔离逻辑检查，并使用 Node 通过 19 项面板显示及按钮回调检查。这些检查使用 SketchUp 对象的测试替身，不能替代 SketchUp 内的实际模型导出和视觉验证。SketchUp 内的人工验收尚未完成，详见 [验证记录](TEST_RESULTS.md)。

测试覆盖实际临时文件字节计数、定义去重、混合选择、失败清理、缓存失效、模型副本、队列取消、切换文档、关闭和重新打开、中文及特殊字符名称、按钮回调、单位换算与错误状态。详见源码压缩包中的 `tests/`。

## 源码结构

```text
src/
  model_size_info.rb              扩展注册入口
  model_size_info/
    main.rb                      菜单入口
    analyzer.rb                  定义去重、文件测量和缓存
    panel.rb                     面板、监听和测量队列
    ui/
      panel.html
      panel.css
      panel.js
tests/
  logic_test.rb
  ui_test.cjs
```

使用可用的 Ruby 2.7+ 执行 `ruby tests/logic_test.rb`；使用 Node 执行 `node tests/ui_test.cjs`。项目不依赖第三方 Ruby gem、网络服务或账号。

重新打包：在项目根目录执行 `python build.py --output-dir dist`，即可生成安装包和源码包。也可以将 `src/` 里面的 `model_size_info.rb` 与同名文件夹放在 ZIP 根目录，再将扩展名改为 `.rbz`；不要把 `src/` 文件夹本身作为压缩包最外层。

## 官方参考

- [组件定义的副本保存 API](https://ruby.sketchup.com/Sketchup/ComponentDefinition.html#save_copy-instance_method)
- [模型的副本保存 API](https://ruby.sketchup.com/Sketchup/Model.html#save_copy-instance_method)
- [SketchUp 扩展的标准目录与打包方式](https://developer.sketchup.com/article-creating-a-sketchup-extension)
- [自定义面板停靠功能的官方问题跟踪](https://github.com/SketchUp/api-issue-tracker/issues/384)
