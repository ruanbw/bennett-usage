# Bennett Usage 界面系统规范（方向 B 深化）

> 配套视觉稿：`docs/ui-refactor/ui-system.html`（可交互，含明暗两套）
> 取代：`design-demos/02-apple-health.html`（保留为方向选择存档，不再作为实现依据）
> 约束来源：`brand-spec.md`、`design-spec.md`、`product-facts.md`
> 本规范只描述界面。不改变解析器、SQLite、同步、计价、汇率、隐私与窗口生命周期。

## 0. 实现落点

规范已落到代码，权威来源是实现文件而非本文档的表格：

| 令牌 | 实现 |
|---|---|
| 全部颜色、字号、间距、圆角、动效时长 | `Sources/BennettUsageCore/Views/DesignTokens.swift` |
| 组件契约（结论带、环、分段、状态胶囊、主按钮、危险按钮、来源行、图表条） | `Sources/BennettUsageCore/Views/DesignComponents.swift` |
| 旧名兼容层（`ContinuousPanel` / `MetricCell` / `ProportionBar` / `SectionEyebrow` …） | `Sources/BennettUsageCore/Views/DesignPrimitives.swift`，已改为转发，不再自持实现 |
| 三界面 | `DashboardContentView` / `MenuBarPopoverView` / `SettingsContentView` |
| 环比取数 | `MetricsAggregator.fetchComparisonPeriod(range:toolFilter:)` |

`AppTheme` 保留为语义别名（`AppTheme.Text.primary` → `DesignTokens.Ink.strong`），只为不打断既有调用点；新代码应直接用 `DesignTokens`。

### 两处与原表格的偏离（均已核验）

1. **`--line-soft` 深色值**：`#292D33` → `#32373E`。原值对 `#22272E` 模块只有 1.09:1，低于分隔线可感知的 1.1:1 下限，实际不可见。色相与职责不变。
2. **OKLch → sRGB 落地**：SwiftUI 无 `oklch()` 构造器，令牌以 sRGB 十六进制存储，每个值在代码注释中保留其 OKLch 出处。全部对比度已按 WCAG 2.1 重算并通过。

---

## 1. 一句话

**先回答「我今天怎么样」，再允许追问「为什么」**：一屏一个结论，颜色只做一件事，所有异常状态都可恢复。

---

## 2. 颜色：三种职责，互不串用

这是本次重构唯一新增的硬约束，用来修掉 `product-facts.md` 里的第 3 条问题（图表色同时承担品牌、分类与状态）。

| 职责 | 令牌 | 用在哪 | 绝不用在哪 |
|---|---|---|---|
| 交互色 | `--accent` | 选中分段、焦点环、主按钮、危险操作描边 | 任何数据、任何图表 |
| 状态色 | `--ok` / `--warn` / `--danger` | 缓存命中环、同步与新鲜度、告警条、失败、危险操作 | 表达数据归属 |
| 分类色 | `AppTheme.Agent` 现有 18 个映射 | 来源、模型、项目的归属色 | 按钮选中态、焦点环 |
| 量级色 | `--fg` 的透明度阶梯 | 趋势面积、热力格、未选中柱 | 表达身份 |

**判定规则**：如果一个颜色回答的问题是「这是谁的」，它是分类色；如果回答「现在能不能信」，它是状态色；如果回答「你正在操作什么」，它是交互色；拿不准就是量级色。

### 2.1 中性令牌

| 令牌 | 浅色 | 深色 | 用途 |
|---|---|---|---|
| `--bg` | `oklch(0.968 0.004 250)` | `oklch(0.185 0.012 258)` | 窗口底色、页面底色 |
| `--surface` | `#fff` | `oklch(0.238 0.014 258)` | 模块、弹窗、面板 |
| `--surface-2` | `oklch(0.982 0.005 250)` | `oklch(0.272 0.015 258)` | 结论带、分组列表底 |
| `--fg` | `oklch(0.245 0.018 258)` | `oklch(0.955 0.004 250)` | 标题、趋势墨色 |
| `--muted` | `oklch(0.462 0.018 256)` | `oklch(0.735 0.014 252)` | 次级说明、标签 |
| `--line` | `oklch(0.912 0.008 250)` | `oklch(0.345 0.014 258)` | 模块边框 |
| `--line-soft` | `oklch(0.940 0.006 250)` | `oklch(0.295 0.013 258)` | 组内分隔线 |
| `--accent` | `oklch(0.545 0.175 258)` | `oklch(0.700 0.150 258)` | 交互色 |
| `--ok` | `oklch(0.575 0.125 162)` | `oklch(0.740 0.130 162)` | 达标 / 正常 / 下降 |
| `--warn` | `oklch(0.665 0.145 68)` | `oklch(0.780 0.135 72)` | 未达标 / 过期 |
| `--danger` | `oklch(0.565 0.185 25)` | `oklch(0.700 0.165 25)` | 失败 / 危险 / 上升 |

**对比度已核验**（WCAG 2.1，浅色/深色分别计算）：

- `--fg` on `--surface` 16.2 : 14.5
- `--muted` on `--surface` 7.1 : 7.1
- `--accent` on `--surface` 5.0 : 6.2
- `--danger` on `--surface` 5.0 : 5.8
- `--ok` on `--surface` 4.1 : 7.6 —— **浅色模式下 `--ok` 不够 4.5:1，作正文时必须用 `--ok-text`**（`--ok` 向 `--fg` 收敛 16%）
- `--warn` on `--surface` 3.2 : 8.1 —— 同理，正文用 `--warn-text`（向 `--fg` 收敛 30%）
- 分类色 on `--surface` 3.2 – 7.6，只作图形（柱、点、环），**不得作正文色**

### 2.2 分类色（一个值都不改）

来源 `Sources/BennettUsageCore/Views/ThemeColors.swift · AppTheme.Agent`，经 `ChartPalette.color(for:)` 解析。本机有记录的 8 项：

| 来源 | 显示名 | 浅色 | 深色 |
|---|---|---|---|
| pi | Pi Agent | `#D97706` | `#FBBF24` |
| omp | Oh My Pi | `#EA580C` | `#FB923C` |
| dsh | DSH Harness | `#1D4ED8` | `#60A5FA` |
| codex | OpenAI Codex | `#0D9468` | `#10B981` |
| antigravity | Antigravity | `#9333EA` | `#D8B4FE` |
| claude | Claude Code | `#CC5C36` | `#E07A5F` |
| opencode | OpenCode | `#475569` | `#94A3B8` |
| cline | Cline | `#0F766E` | `#2DD4BF` |

> 注意：`design-demos/02-apple-health.html` 给 Antigravity 画了蓝色，与本映射冲突。**实现以本表为准。**

---

## 3. 排版与尺寸

- 标题：SF Pro Display；正文：SF Pro Text；数字与代码：SF Mono + tabular figures。本产品是 macOS 原生工具，不使用衬线体。
- 字号：50 / 34 / 17 / 15 / 13 / 11.5，全部走动态字体（`.dynamicTypeSize(... )`），不写死 pt。数字容器预留 25% 余量，缩写不截断。
- 8pt 基线。窗口内距 20，模块间距 14，模块内距 16/17，控件行高 ≥ 44（可点区域），工具栏图标 30×30。
- 圆角：控件 6 / 模块 10 / 结论带 14 / 弹窗 14 / 窗口 12。
- 边框只有两级：`--line`（模块）与 `--line-soft`（组内分隔）。不使用投影堆叠，不用「彩色竖条 + 圆角卡片」。

---

## 4. 组件契约

| 组件 | 尺寸 | 内容 | 状态 | 可访问性 |
|---|---|---|---|---|
| 结论带 | 高 ≈ 148 | 结论标题 + 总量大数 + 环比 + 结论句 + 3 项次级指标 + 缓存环 | normal / stale / error | 总量、费用、命中率各有文字描述，不只靠环 |
| 次级指标 | 竖排 3 列 | 预估费用 / 缓存命中 / 覆盖天数 | 数值变动 180ms 插值 | 等宽数字，不跳动 |
| 缓存环 | 104×104（弹窗 62） | 只编码缓存命中率 | ≥95% 绿 / <95% 琥珀 / 动画 520ms | `accessibilityValue` = 百分比 |
| 范围分段 | 高 30 | 24 小时 / 今日 / 7 天 / 30 天 / 1 年 | default / hover / selected / focus | `⌘1`–`⌘5` |
| Agent 芯片 | 高 26 | 圆点（分类色）+ 名称 | default / hover / selected | 选中态由主色描边承担，不改圆点色 |
| 来源行 | 高 24 | 名称 + 填充条 + Token + 占比 | default / hover / selected | 整行可点，`aria-pressed` 等价物为 `isSelected` |
| 趋势图 | 高度自适应 | 面积 + 折线 + 悬停十字线与浮层 | 悬停显示 期间 / Token / 占比 | 附一行文字摘要供 VoiceOver |
| 状态胶囊 | 高 24 | 圆点 + 文案 | ok / syncing / stale / error | 文案本身即状态，不只靠颜色 |
| 分组列表 | 行高 ≥ 46 | 标题 + 说明 + 控件 | default / hover / focus | 原生 `Form` / `List` 语义 |
| 危险按钮 | 高 28 | 红色描边文字 | default / hover / focus / 确认中 | 不与主按钮并排 |

**按钮层级**：一个界面一个主按钮。Dashboard 主按钮 = 「打开 Dashboard」（弹窗内）；Dashboard 内主操作为分段选择与刷新图标，不设第二个实心按钮。

---

## 5. 三界面骨架

### 5.1 Dashboard（1080×740）

```
标题栏 38
工具栏 52  标题 · 范围分段 · 状态胶囊 · 刷新 · 设置
第一屏
  结论带              ← 总量 / 环比 / 结论句 / 费用 / 命中 / 覆盖天数 / 环
  Highlights 72       ← 主要来源（本范围）· 主要模型（近 24h）· 主要项目（近 24h）
  趋势（2fr） | 来源贡献（1fr）
  页脚                ← 本地 SQLite · 33 天记录 · 无需账号
第二屏（滚动）
  模型分布 | 项目排行
  年度热力图
```

顺序不可调整。Highlights 用发丝线分隔的**定义列表**，不再用三张等权卡片。

模块口径：模型与项目在原型中只有「近 24 小时」口径，因此各自带一个口径标签；接入 `MetricsAggregator` 的全范围聚合后，标签跟随全局范围。

### 5.2 菜单栏弹窗（360pt）

```
拖拽把手
① 今日 Token（34px）+ 环比 + 缓存环
② 费用 / 来源数 两格 + 数据新鲜度胶囊
③ 消耗最多：2 行来源
——————
主按钮：打开 Dashboard
次级：立即同步 · 设置 · 退出（44pt 图标行）
```

三层封顶。相对原稿的删除清单：第 4 个按钮、重复的百分比、完整来源榜单、主题入口。

### 5.3 Settings（750×510）

侧栏五项固定顺序：通用 / Agent 状态 / 计价与汇率 / 数据与存储 / 关于本应用。侧栏底部常驻四条状态：数据源 x/18、记录天数、更新状态、隐私。主区用分组列表，不用描边卡片堆叠。危险操作只在「数据与存储」出现。

---

## 6. 状态矩阵

| 状态 | 触发 | 界面表现 | 必须可操作 |
|---|---|---|---|
| loading | 首次进入 / 切范围 | 保留结论带版式骨架的骨架屏，不盖整页转圈 | 可取消 |
| empty | 该范围无记录 | 「30 天内没有使用记录」+ 切范围 + 立即同步 | 切范围、同步 |
| stale | 距上次同步 > 阈值 | 结论带转琥珀底 + 标注「可能不完整」，数字照常显示 | 立即同步 |
| syncing | 扫描进行中 | 逐来源进度列表 + 脉冲胶囊，数据仍可读 | 可继续浏览 |
| error | 单来源解析失败 | 红色告警条点名来源 + 「总计可能偏低」+ 重试该来源 / 查看日志 | 重试、看日志 |
| partial | 模型无价格表 | 行内标注「无价格表」，费用显示 `—` | 查看明细 |

失败按来源隔离：一个来源失败不阻塞其余数据，也不清空整屏。

---

## 7. 键盘、焦点、动效

- Tab 顺序：工具栏 → 范围分段 → 来源筛选 → 图表 → 列表。
- 快捷键：`⌘R` 立即同步 · `⌘,` 设置 · `⌘⇧D` Dashboard · `⌘1`–`⌘5` 时间范围。
- 焦点环 2px `--accent` + 2px 偏移，任何状态都不得移除。
- 悬停 120ms，只过渡背景与边框，不做位移与阴影。
- 数值 180ms 线性插值，环形 520ms ease-out。全部尊重「减弱动态效果」。
- 不靠颜色单独表意：涨跌带箭头与文字，来源带名称与数值，状态带圆点与文案。

---

## 8. 落地检查（给三个 Lane 的 Writer）

- [x] 结论带是一整块连续容器，不是三张卡片。 → `DashboardContentView.conclusionPanel`
- [x] 全屏没有第三个实心按钮。 → 弹窗 `actionBar` 一个 `PrimaryAction` + 三个 `SecondaryIconAction`；设置页的实心按钮仅限“立即检查更新”一处
- [x] 图表颜色里没有出现 `--accent`。 → `ChartPalette` 只用身份色；趋势线与单系列标记已改为墨色
- [x] Agent 芯片的选中态没有改圆点颜色。 → `AgentFilterBarView` 选中由主色描边承担
- [x] 每个模块都能说出自己的时间口径。 → `ScopeTag` + 各图表副标题
- [x] loading / empty / stale / syncing / error / partial 六态都有实现。 → `StateCapsule.Level` 覆盖 ok/syncing/stale/error；empty 与 partial 分别为空态与 `partialComparisonCoverage`
- [x] 明暗两套都跑过，最小文字对比度 ≥ 4.5:1。 → 实测 26 组配对全部通过；`--ok` / `--warn` 另设 `-text` 变体（4.55 / 4.54）
- [x] 数值全部 tabular figures，动态字体不截断。 → `TypeScale.numeric*` + `minimumScaleFactor(0.5–0.6)`
- [x] 没有引入新的 Agent 颜色，没有改动 `AppTheme.Agent`。 → 18 项逐字节比对，0 偏差

### 实施中修正的三个实际缺陷

1. **深色模式主按钮不可读**：范围分段选中态硬编码 `Color.white`，而深色 accent 是浅蓝，白字只有 2.69:1。改为 `Accent.onFill`（深色下近黑前景，7.11:1）。
2. **环比可能说谎**：`cacheHitRate` 把 `inputTokens` 计入分母，导致无缓存数据时返回 `0.0`——“未测量”被读成“缓存失效”。现在无 `cacheReadTokens` 时返回 `nil`，界面显示“—/未测得”并画不出弧线。
3. **焦点环形同虚设**：初版用 `focusEffectDisabled()` + `opacity(0)` 的静态描边，永远不可见。现由各控件自持 `@FocusState` 驱动，仅键盘焦点时显形。
