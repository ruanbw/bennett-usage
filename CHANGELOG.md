# Changelog

## v1.0.0 — 2026-09-13

第一个正式版本：macOS 菜单栏常驻，聚合 6 个 AI coding 助手的本地 Token 用量。

### Dashboard

- 时间范围：24 小时 / 今日 / 7 天 / 30 天 / 过去一年 / 按年
- 小时级 Token 趋势，按模型堆叠，柱状 / 折线可切换
- 工具消耗占比、模型消耗占比环图，悬停看明细
- 年度全景：热力日历 / 月度趋势两种视图，未来日期自动隐藏
- KPI：总 Token、区间支出、新增输入、模型输出、缓存写入 / 命中 / 命中率
- 项目排行、Agent 筛选、年 / 区间维度独立刷新

### 菜单栏

- 常驻显示今日用量，点击弹窗：今日 Token、预估费用、今日各工具分布
- 一键立即同步、打开 Dashboard / 设置、退出

### 数据源

- Claude Code、OpenAI Codex、Gemini CLI、Oh My Pi、Pi Agent、Antigravity
- 本地解析会话记录，增量同步，FSEvents 文件监听自动触发
- SQLite 本地存储（`~/Library/Application Support/BennettUsage/usage.db`）

### 计价与设置

- 内置模型单价（输入 / 输出 / 缓存读 / 缓存写），USD / CNY 切换，汇率自定义
- 通用 / Agent 状态 / 计价与汇率 / 数据与存储 / 关于，五组设置页
- 中英双语（简体中文 / English / 跟随系统），自动刷新频率可配

### 工程

- 130 个测试全绿；同步并发化、SQL 下推聚合、视图按需刷新
