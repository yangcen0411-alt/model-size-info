# 模型占用信息 · SketchUp 插件

版本：1.5.0（Windows 后台处理版，开发版）

[下载插件安装包](https://github.com/yangcen0411-alt/model-size-info/raw/refs/heads/main/downloads/model_size_info_v1.5.0.rbz) · [下载源码](https://github.com/yangcen0411-alt/model-size-info/raw/refs/heads/main/downloads/model_size_info_v1.5.0_source.zip)

**先保存模型，再打开插件。** 面板显示已保存的 SKP 文件大小和组件树。展开箭头查看子项，点击行内“计算大小”显示该定义独立保存为 SKP 的实际 KB / MB。点击数值可重新计算。

## 1.5.0 的变化

层级读取、SKP 解析、临时副本复制和组件导出全部放到独立后台程序中。SketchUp 只接收每页最多 100 个目录条目和计算结果。“停止后台任务”可以终止正在执行的后台进程。

后台通过 SketchUp C API 的群组、组件专用接口读取目录。当前层的面和线不逐项送回 SketchUp，未展开的子级保持按需读取。

**数据来源是上次保存的文件。** 未保存的新模型需要先正常保存；编辑后会显示“结果来自上次保存”。保存完成后自动重新读取，也可点击右上角刷新。后台处理临时文件中的独立副本。

本版操作集中在组件树和单项计算。整个模型的文件大小显示在顶部。旧版的自动选择测量、当前未保存模型副本测量和批量导出入口已移除。

## 安装和打开

支持 **Windows x64 的 SketchUp 2022 及更新桌面版**。后台程序使用已安装 SketchUp 中的 `SketchUpAPI.dll`，需要 Windows .NET Framework 4.x。本包包含自行编译的后台程序及其源码，不包含 SketchUp SDK 的 DLL。macOS 和网页版不支持本版后台功能。

1. 下载 `model_size_info_v1.5.0.rbz`，保留后缀，无需解压。
2. 在 SketchUp 的“扩展程序管理器”中选择“安装扩展程序”。
3. 从旧版升级后重启 SketchUp。
4. 保存模型，点击“模型占用信息”工具栏的绿色立方体按钮。也可从扩展程序菜单或建模区域右键菜单打开。
5. 在“更多”底部确认版本为 **v1.5.0**。

Windows 可在“视图 → 工具栏”中勾选“模型占用信息”。本插件未经过 Extension Warehouse 签名；如管理器要求批准，请仅批准此插件。

## 使用

- **展开箭头**：后台读取这一项的子级，相同定义复用结果。
- **计算大小**：后台导出该定义的完整 SKP，数值包含其嵌套内容。计算子项时只导出该子项。
- **点击数值**：重新计算这一项，其他结果保留。
- **点击名称**：在当前模型中选择对应对象。嵌套对象会进入父级编辑环境。对象已移动或变化时会提示保存并刷新，锁定对象保持锁定。
- **再读取 100 项**：请求当前层的下一页。大目录不会一次全部传回面板。
- **更多**：排序当前已读取的项目、收起全部、查看统计与说明。
- **停止后台任务**：终止后台进程，保留已完成的目录与结果。读取任务可点击“继续读取”；被停止的计算需重新点击。
- **刷新**：丢弃当前结果，重新分析最新保存的文件。

父级大小包含子级，跨层相加会重复计入子级。同一定义的多个实例共享结果。隐藏和锁定的群组/组件会列出，未使用的定义不作为目录项目。

## 大小的含义

数值来自后台程序调用 `SUComponentDefinitionSaveToFile` 实际写出的独立 SKP 文件。包括该定义内的几何、材质、嵌套对象等数据。实例外层的缩放或材质覆盖不属于定义文件。

不同定义独立导出的文件可能重复包含材质、共享子组件和文件头。数值不表示删除该对象后原模型会减少多少，也不能直接按嵌套层级求和。1 KB = 1024 字节，1 MB = 1024 KB。

源 SKP 只用于后台读取。导出和文件接口对定义产生的改动只作用于后台私有副本。临时目录在关闭、取消或重新加载时清理。

## 资源和限制

后台会额外加载一份模型，需要额外内存和临时磁盘空间。程序以较低优先级运行，并使用 Windows 进程内存限制，上限为启动时可用物理内存的一半且不超过 6 GB。可用内存小于 768 MB 时拒绝启动。达到资源限制时，后台任务可能失败或退出；面板会显示错误。

后台启动等待上限为 5 分钟，单项读取或计算等待上限为 3 分钟。超时会终止后台任务。关闭面板、切换文档和刷新也会结束该面板自己的后台进程。

这些措施减少了插件在 SU 内执行长任务的情况。后台分析仍会使用内存和磁盘，实际响应取决于模型和机器资源。尚未完成用户实际大模型在 SketchUp 界面内的验证，不保证所有模型的耗时或响应。

## 验证

- 49 项 Ruby 面板与目录检查，包含停止、恢复、保存刷新、过期任务、共享缓存、目录分页及错误处理。测试中的当前模型一旦被要求访问几何、全局定义、直接导出或自动缩放就会报错。
- 24 项 JavaScript 检查，包含行内计算、共享数值、后台状态、分页、保存来源提示和菜单操作。
- 10 项工具栏检查。
- 17 项真实 C API 后台检查，使用自行生成的 SKP，覆盖中文路径、206 个对象分页、原始几何过滤、真实导出、缓存、临时文件清理、源文件保持一致、停止与重新启动、损坏文件、Windows 内存限制。另有 3700 个不同组件定义位于同一父级的真实 SKP 场景。
- Ruby 与实际后台程序的联调通过，覆盖中文及引号路径、启动、分页、真实计算、源文件保持一致、退出检测和目录清理。
- 独立浏览器回放 Ruby 面板消息，检查 380 × 560、320 × 360、440 × 740 窗口、12 层嵌套、停止继续及分页。

以上真实文件检查在独立进程中运行 SketchUp 2026 的文件接口，没有启动或操作用户的 SketchUp 文档。详细范围见 [验证记录](TEST_RESULTS.md)。

## 开发和打包

运行 `ruby tests/tree_test.rb`、`ruby tests/toolbar_test.rb` 和 `node tests/ui_test.cjs`。真实后台检查使用 `python tests/native_worker_test.py --api "<已安装的 SketchUpAPI.dll 路径>"`。Ruby 联调先设置 `MODEL_SIZE_TEST_SKP` 为测试模型路径、`MODEL_SIZE_TEST_API` 为 DLL 路径，再运行 `ruby tests/session_test.rb`。

后台源码在 `worker/ModelSizeWorker.cs`。Windows 上使用 `python worker/build_worker.py` 重新编译 x64 后台程序，之后运行 `python build.py --output-dir dist` 打包。构建需要 Windows .NET Framework 的 C# 编译器。

## 官方参考

- [独立文件处理与实时模型接口的区别](https://stg-extensions.sketchup.com/developers/sketchup_c_api/sketchup/index.html)
- [群组与组件的专用读取接口](https://stg-extensions.sketchup.com/developers/sketchup_c_api/sketchup/struct_s_u_entities_ref.html)
- [组件定义文件导出](https://stg-extensions.sketchup.com/developers/sketchup_c_api/sketchup/struct_s_u_component_definition_ref.html)
- [Windows 进程内存限制](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-jobobject_extended_limit_information)
- [SketchUp 工具栏](https://ruby.sketchup.com/UI/Toolbar.html)
