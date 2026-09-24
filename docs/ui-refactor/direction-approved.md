# UI 重构方向确认

## 用户选择

- 原话：`B`
- 选择方向：方向 B · Apple Health-inspired
- 选择日期：2026-09-24

## 已展示方向

### 方向 A · Swiss Monochrome

- HTML：`design-demos/01-swiss-monochrome.html`
- 截图：`design-demos/01-swiss-monochrome.png`
- 逻辑：秒数轮盘第 19 号
- 核心：数据简报、规则线、极高对比

### 方向 B · Apple Health-inspired

- HTML：`design-demos/02-apple-health.html`
- 截图：`design-demos/02-apple-health.png`
- 逻辑：现实参照 Apple Health
- 核心：先给整体状态，再给 highlights 与趋势；柔和浅色、连续容器、语义色

### 方向 C · Carbon Console

- HTML：`design-demos/03-carbon-console.html`
- 截图：`design-demos/03-carbon-console.png`
- 逻辑：IBM Carbon Design System
- 核心：模块化数据工作台、状态条、高密度扫描

## 执行约束

- 三个核心界面统一采用方向 B 的信息层级和视觉语汇。
- 允许重构布局、视觉层级和交互反馈。
- 不改变 Agent 解析、SQLite、同步、计价、汇率和隐私逻辑。
- 优先使用 SwiftUI 原生控件与语义样式，避免为视觉牺牲辅助功能能力。
