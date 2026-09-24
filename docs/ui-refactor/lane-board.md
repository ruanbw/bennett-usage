# UI/UX 重构并行执行 Lane Board

## 总体分类

- 类型：multi-seam
- 仓库：`/Users/ruanbw/projects/bennett-usage`
- 当前分支：`main`
- 方向：用户已选择 B（Apple Health-inspired）
- 目标：重构菜单栏弹窗、Dashboard、Settings 的信息架构、视觉层级和交互反馈
- 不可变边界：不改变解析器、SQLite、同步、计价、汇率、隐私和窗口生命周期

## 并行写入边界

| Lane | 组件 | 独占文件 | 允许的改动 | 验证责任 |
|---|---|---|---|---|
| dashboard | Dashboard 首屏 | `Sources/BennettUsageCore/Views/DashboardContentView.swift` | 重组首屏布局、摘要卡、highlights、趋势与来源层级；复用现有数据和加载方法 | 静态编译检查由父代理统一执行 |
| popover | 菜单栏速览 | `Sources/BennettUsageCore/Views/MenuBarPopoverView.swift` | 重排速览层级、状态提示、主动作和 accessibility；不改同步回调 | 静态编译检查由父代理统一执行 |
| settings | 设置与主题 | `Sources/BennettUsageCore/Views/SettingsContentView.swift` | 重排设置分组、控件反馈、空状态与状态侧栏；不改设置状态模型 | 静态编译检查由父代理统一执行 |

## 集成边界

- 父代理独占 `ThemeColors.swift`、`DashboardView.swift`、`SettingsSheetView.swift` 及最终验证。
- 三个子代理不得修改其他 Lane 文件，不得提交、推送、重置或清理工作树。
- 共享工作树当前包含已批准的 `docs/ui-refactor/` 与 `design-demos/` 未跟踪文件，不能删除或覆盖。
- 父代理在三个 Writer 完成后统一处理编译错误、主题 token、窗口尺寸和跨界面一致性。

## 质量门

1. 三个 writer 都只修改自己的独占文件。
2. 父代理执行 `swift test` 和 `swift build`。
3. 检查 git diff 只包含 UI 重构范围内的预期文件。
4. 如条件允许，启动 macOS App 截图验证 Dashboard、Settings 和菜单栏弹窗。
5. 独立 reviewer 只读检查最终 diff，父代理筛选并修复 P0/P1。
