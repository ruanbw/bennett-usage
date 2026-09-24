# Changelog

## Unreleased

## v1.5.0 — 2026-09-24

### 视觉系统重构

本次是一次完整的视觉与信息架构重构，核心问题是**同一个颜色同时承担多个角色**，以及**所有区块长得完全一样**。改动建立了一条明确规则并写进代码：界面家具只有一种强调色（`Chrome`），状态色只在描述状态时出现（`Status`），Agent / 模型品牌色只允许出现在数据图元上（`Agent` / `Harmonic` / `Data`）。此前橙色同时表示 Pi Agent、缓存写入警告、设置里的「计价与汇率」和项目区标题图标，屏幕上没有一种颜色能被读出含义。

- **配色角色分离**（`ThemeColors.swift`）：新增 `Chrome`（交互与选中，唯一的强调色）与 `Data`（数据图元的中性轨道 / 单系列色）命名空间，并明确记录三类颜色的职责边界。
- **状态色不再误用**：金额（`$0.18`）此前用成功绿渲染，读起来像一盏状态灯，现改为主文本色；设置页「USD」此前用警告橙；Token 构成的四类（输入 / 输出 / 缓存读写）此前取自状态色，现改用数据色阶。
- **装饰性图标全面移除**：每个标题和每个设置行原本都有一个彩色圆角图标块，其中若干直接取自 Agent 品牌色。改用字距放大的微标签（`SectionEyebrow`）承担分组标识；设置页五分类侧栏原本五个不同颜色，现统一为中性色，仅选中态使用强调色。
- **卡片墙改为连续容器**：新增 `DesignPrimitives.swift`，提供 `ContinuousPanel` / `PanelDivider` / `MetricCell` / `ProportionBar` / `StatusMarker` / `PercentageMeter`。原先所有区块都是同样的白底描边卡片，没有视觉焦点；现由单个容器加分隔线组织成组。
- **比例条改为中性轨道**：Agent / 模型分布条此前是满幅饱和填充，占比最高的 Agent 会占满整屏；现绘制在中性轨道上、收窄至 6–8pt，仅作定位用，实际读数交给下方列表。
- **去除游戏化**：项目排名的金 / 银 / 铜奖牌色改为中性等宽数字，既符合品牌规范中「避免游戏化」的要求，也避免与 Agent 品牌色混淆。

### 信息架构

- **Dashboard 首屏合并为单个结论面板**：原先拆成两张同样式卡片，导致「24 小时」在首屏重复出现四次。现在总量独占左侧三分之一，费用与缓存命中率并列，三个主要贡献来源共享下方一行，同处一个容器内。
- **消除真实冗余**：「今日」卡原先无条件渲染，紧贴结论面板下方重复同样的三项读数（3.29B / $0.17 / Pi Agent 对 3.28B / $0.18 / Pi Agent）。现仅在所选范围不是「今日」时出现，且降为浅色次级样式。
- **趋势图独占整行**：原先与 Agent 卡并排，右侧留下约 250pt 死白。趋势独占宽度后，与「Token 构成 / Agent 用量」共享下一行，符合「何时变化 → 谁在消耗」的优先级。
- **趋势图增加结论条**：峰值（含发生时刻）、均值、活跃区间数，让图表支撑一个结论而不是替代结论。
- **时间范围不再逐卡复述**：范围由上方控制条统一表达，各卡片不再重复显示。

### 菜单栏弹窗

- 从 386 × 626 收敛到 366 × 475，恢复「三秒速览」定位，不再是缩小版 Dashboard。
- 移除与菜单栏状态项重复的产品名头部；同步状态合并进标题行，取消原先独占一整条的主题色面板。
- 迷你趋势图补上基线与峰值标注（原先悬浮在空白中、没有刻度，无法判断是尖峰还是平缓）。
- 每行只显示一次占比，去掉与列表重复的「主要 Agent」行。

### 设置页

- 每行从约 100pt 压缩到 44pt：移除 30pt 彩色图标块后行高回到原生设置的水位。
- 移除每页开头与详情页头部逐字重复的标题和副标题（原本「通用设置」及其副标题在同一页出现两次）。
- 隐私声明从并排的两处近似文案合并为一处。
- 侧栏顶部的「设置」根行从可选中的样式改为静态分组标签（原本看起来像第六个可点目的地）。

### 回归修复

- `settingsCard` 水平内边距保持与详情栏内缩一致（20pt），以维持下拉控件与卡片右缘齐平的既有布局契约（`testSettingsDropdownsAreRightAlignedWithCardEdge`）。


## v1.4.1 — 2026-09-24

### UI/UX 重构

- **Dashboard**：采用 Apple Health-inspired 的信息层级，首屏先呈现总量、费用与缓存命中率，再展示最多三个真实贡献亮点、趋势和来源探索；增加窄窗口响应式 fallback，保留年度热力图与项目排行。
- **菜单栏弹窗**：重排为今日结论、真实同步状态、Agent 来源和分级动作；同步状态与数据库读取时间解耦，失败或进行中的同步不再显示成功。
- **设置页**：采用更接近 macOS 原生设置的侧栏与分组结构，增加状态胶囊、保存反馈、加载/不可用状态和非法汇率提示，移除重复关闭按钮。
- **可访问性与本地化**：保留中英文、键盘动作、辅助功能标签和本地隐私承诺；补充同步状态相关测试。

### 新增适配器

- **Kimi Code**：解析当前 `$KIMI_CODE_HOME`（默认 `~/.kimi-code`）下 `sessions/**/agents/**/wire.jsonl` 的 `usage.record`；完整导入互斥的 `turn` / `session` 单次请求增量，独立映射 fresh input、输出与缓存读写字段。通过文件代际游标只读取完整换行，截断尾行留待下次，重写触发本地记录重建；不读取旧版 `~/.kimi/context.jsonl`。wire 未提供权威 provider、request id、reasoning 或费用，因此不猜测这些字段，费用仅由本地价格表估算。
- **Continue CLI**：解析 `~/.continue/sessions/<session UUID>.json` 中 `history[i].message.usage` 的逐条 assistant 用量；支持绝对路径 `CONTINUE_GLOBAL_DIR` 覆盖，忽略会话索引 `sessions.json`，并按文件修改时间、文件大小和文件身份维护增量游标。会话文件重写时使用不含 usage 的消息语义哈希作为稳定 ID，避免 usage 后补全或重复扫描造成重复消费。
- **Goose**：新增只读 SQLite `usage_ledger` 适配器，支持 macOS 默认路径与绝对 `GOOSE_PATH_ROOT`；按数据库 identity + ledger row id 增量同步，schema 不兼容时安全跳过；忽略 `carried_forward`，用每会话 deterministic synthetic baseline 保留累计差额，避免重复计费。
- **Crush**：从 `CRUSH_GLOBAL_DATA` / XDG / macOS 默认全局目录读取 `projects.json`，按项目枚举 `data_dir/crush.db`。SQLite 以只读、全互斥、`query_only` 和 busy timeout 打开，不执行迁移或修改 WAL。
- 默认仅统计顶层 session 的累计 `prompt_tokens`、`completion_tokens` 与原始 `cost`；首次扫描输出全量快照，后续仅输出非负增长，同秒累计变化也通过内容指纹保持幂等。累计值重置或数据库 identity 改变时进入新 generation / 既有 databaseIdentity cutover，绝不输出负 token 或负 cost，reported zero cost 原样保留。
- `projects.json` 中仍存在的项目数据目录会作为 auxiliary watch roots；项目路径用于映射排行，混合消息模型的 session 统一使用稳定的 `crush` 模型标识。

## v1.4.0 — 2026-09-21

全新「极简」界面：仪表盘、菜单栏弹窗与设置页统一为 Things 3 风格的编辑式排版；同时修复 OpenCode V2 适配器读不到数据的问题。

### 界面重构

- **统一设计令牌（`ThemeColors.swift`，新增）**：画布 / 表面 / 文本 / 分隔线 / 状态 / 热力图 / 图表全套语义色，浅色与深色各取一档并随系统外观实时切换；`ChartPalette` 改由令牌驱动，为 14 个 Agent 各配一个稳定的低饱和品牌色——同一个 Agent 在任何图表里颜色一致，不再每次启动换色。
- **仪表盘**：
  - Hero KPI 去掉卡片嵌套，改为无边框编辑式色带：32pt 圆体大数字 + 右侧支出，下方五项指标（新增输入 / 模型输出 / 缓存写入 / 缓存命中 / 缓存命中率）以 0.5pt 细分隔线横向排布；
  - 趋势图改用渐变面积 / 圆角柱形与虚线网格，悬停提示换成毛玻璃浮层；
  - 工具分布与模型分布用**分段式比例条**取代环形图，下方是 Top 4 贡献者列表（色点 + 占比 + Token + 支出）；
  - 年度全景：年度指标条、52 周热力图（5 级绿色梯度、11×11pt 圆角单元格）、当日明细条；
  - 项目排行以 `01` / `02` / `03` 等宽数字取代 🥇🥈🥉 emoji，并附相对占比的 3pt 微进度条；
  - 顶部筛选栏改为「色点 + 名称」的轻量胶囊，选中态用淡色底而非描边。
- **菜单栏弹窗**：改用系统毛玻璃材质与无卡片布局，今日 Token / 支出 + 迷你分段分布条 + 紧凑工具列表，底部保留「立即同步」与「退出」。
- **设置**：按 macOS 系统设置的分组内嵌样式重排（单一表面 + 10pt 圆角 + 行间 0.5pt 细分隔线），Agent 健康页使用 6pt 状态点，关于页展示真实 bundle 图标。
- **主题测试**：新增 `ThemeColorsTests`，覆盖浅 / 深色解析、14 Agent 调色板完备性与取色稳定性。

### 修复与优化

- **OpenCode V2 适配器**：OpenCode V2 已把消息迁到 `session_message` / `session_v2` 表，旧适配器仍按 `message` 表探测，探测失败后回退到更早的 JSON 文件路径，结果一条记录都读不到，OpenCode 在仪表盘上完全消失。现在按数据库实际存在的表选择 V2 / V1 / JSON 后端。
  - 角色取自 `session_message.type`，项目目录回退到 `session_v2.directory`；
  - 进行中的回合（只有 `time.streamed`、尚未写回 `tokens`）不会被游标跳过：其 rowid 留在待复查集合中，回合结束补齐 Token 后再次入库；
  - `tokens.reasoning` 计入输出——OpenCode 单独上报推理 Token（`session_v2` 累计值可证 `tokens_output` 不含 `tokens_reasoning`），而 provider 按输出价计费。
- **统计同步与状态栏更新优化**：
  - 修复 `SyncCoordinator` 并发重入时丢失后续 `changedPaths` 的事件丢失缺陷，引入路径累计缓冲区；
  - 增加动态目录检测，当新 Agent 目录建立时自动热重载并扩充 FSEvents 监听池；
  - 修正 DSH 监听根路径，覆盖 `sessions/` 与 `storages/session_projcache/`；
  - 针对单文件适配器（如 OMP `stats.db`）自动截取父目录监听；
  - `StatusItemController` 增加 30 秒后台心跳定时同步、午夜跨天（`NSCalendarDayChanged`）及电脑休眠唤醒（`NSWorkspace.didWakeNotification`）感知；
  - 将状态栏数据库读取与主线程隔离，消除 SQLite 锁竞争导致的 UI 卡顿。

### 文档

- **README 中英双语**：`README.md` 改为英文（GitHub 默认展示），新增 `README.zh-CN.md` 简体中文版，两份内容一一对应、顶部互相跳转；补充版本 / 平台 / 架构 / 纯本地 / License 徽章、源码构建新增 `swift test`、数据源表格补上 Cline 与 DSH 的环境变量覆盖说明。
- **设计规范与实施计划**：新增 `docs/superpowers/specs/2026-09-20-minimalist-ui-ux-refactor-design.md`（设计令牌、组件分解、验收标准）与 `docs/superpowers/plans/2026-09-20-minimalist-ui-ux-refactor.md`。

## v1.3.0 — 2026-09-16

新增「检查更新」：读取 GitHub Releases 判断是否有新版本，并在设置与菜单栏弹窗中提示。

### 更新检查

- **版本比较**：宽松解析发布标签（`v1.3.0` / `1.3` / `1.3.0-beta.1` / `+build` 均可），按 SemVer 规则比较数字段与预发布标识；预发布版本只对同样是预发布的构建可见，正式版用户不会被推送到 alpha。
- **三种入口**：设置 → 关于 的「检查更新」按钮（手动，永远不会被节流吞掉）、通用页「自动检查更新」开关（默认开启，可在意隐私时关闭）、菜单栏弹窗中的更新横幅；发现新版本时菜单栏图标切换为下载箭头并在 tooltip 中标注版本。
- **自动检查节流**：启动时检查一次，之后每 6 小时询问一次，实际请求由 24 小时节流窗口与用户开关共同决定；检查失败不写入节流时间戳，下次启动仍会重试。
- **架构匹配下载**：优先给出与本机架构一致的 DMG（arm64 / x86_64），缺失时回退 universal，再回退任意 DMG 或发布页。
- **跳过版本**：可跳过某个版本，仅在出现更新版本时再次提醒，可一键恢复提醒。
- **隐私**：仅向 GitHub Releases 公共接口发起一次匿名 `GET`（无 Token、无本地数据），请求内容不含任何用量或项目信息；可在设置中关闭。
- **版本号来源修正**：应用版本改为优先读取打包写入的 `CFBundleShortVersionString`，并同步修正编译期内置常量（此前停留在 `1.1.1`，会让检查更新误报新版本）。

### 应用图标

- **首个正式图标**：蓝紫渐变圆角方块 + 上升柱状图 + 金色 sparkle。形状、尺寸与投影按系统图标实测参数绘制（图标方块占画布 79.7%、超椭圆指数 5.8、投影衰减与 Apple 自带图标误差 ≤ 4/255）；`.icns` 十个尺寸逐档原生渲染而非缩放，16 / 32 px 自动简化为纯白柱子以免糊成一团。
- **可复现生成**：`swift scripts/make-app-icon.swift` 生成 `packaging/AppIcon.icns`，打包脚本自动放进 `Contents/Resources` 并写入 `CFBundleIconFile`；设置 → 关于页的图块改用真实 bundle 图标（`swift run` 等无图标场景回退到原渐变图块）。

## v1.2.0 — 2026-09-16

新增 Cline 独立版（桌面版 / `cline` CLI）适配器，数据源 13 → 14 个。

### 新增适配器

- **Cline（桌面版 / CLI）**：解析 `~/.cline/data/sessions/<sessionId>/<sessionId>.messages.json` 每条 assistant 消息的 `metrics`（`inputTokens` / `outputTokens` / `cacheReadTokens` / `cacheWriteTokens`）与 `modelInfo`（真实模型 id、provider），按稳定消息 id 去重；`CLINE_DIR` / `CLINE_DATA_DIR` / `CLINE_SESSION_DATA_DIR` 可改数据目录。与既有的 Roo Code·Kilo（VSCode 扩展 `globalStorage/*/tasks`）适配器互不重叠。
  - 会话清单（`<sessionId>.json`）的 `metadata.usage` 累计值仅在缺少转录文件时兜底，避免与逐条记录重复计费；
  - `apps/<app>/sessions/*.jsonl` 事件流按 `chat_usage` 事件逐请求解析（忽略其中的累计值），且只用于规范目录中不存在的会话 id，同样杜绝重复计费；
  - 会话在没有项目目录（`workspace_root` 为 `/`）时不写入项目排行。

## v1.1.1 — 2026-09-14

修复 DSH Harness 适配器模型归属与双重计费 Bug，数据库支持自愈重构。

### Bug 修复与优化

- **模型名归属精准化**：移除对外部全局默认模型的猜测，严格按 DSH 会话转录日志（`session.v3.jsonl.zstd`）各消息内部记录的实际模型（如 `gemini-3.8-flash-high`、`muse-spark-1.3-contributor`、`deepseek-v4.1-flash`）独立归属；彻底杜绝模型饼图中出现 `"dsh"` 工具名。
- **杜绝并发写入时的重复计费**：消除活跃写入转录文件时误触发 Projcache 回退导致的 Token 双重计数问题。
- **历史数据自愈**：数据库初始化时自动检测并清理历史遗留的 `"dsh"` 虚假模型和重复累计记录，无缝重放准确数据。
- **计价规则补充**：补充 OpenCode 平台 Muse 系列模型（`muse*`）的计费规则。

## v1.1.0 — 2026-09-14

数据源 6 → 13 个，之前占位的 Claude / Codex 转正。

### 新增适配器

- Claude Code：`~/.claude/projects` JSONL 真实解析，按 `message.id` 去重（流式扇出不重复计）
- OpenAI Codex：`~/.codex/sessions` rollout 日志 `token_count` 事件增量解析
- Qwen Code：`~/.qwen`（`QWEN_HOME` 可改），Gemini 同构
- OpenCode：`opencode.db` SQLite，`storage/message` JSON 回退
- Roo Code·Cline·Kilo：VSCode 系 `globalStorage/*/tasks` 历史
- DSH Harness：`session.v3.jsonl.zstd` 逐 step 解析（`zstd` CLI），无 CLI 时回退 projcache 累计 delta
- GitHub Copilot / Cursor / Trae：云端计费，仅检测安装状态（等 API 适配器）

### 其他

- 计价新增 Claude-4、GPT-5/4.1、o4-mini、Gemini-2.5/3、Qwen3、Kimi-K2、GLM、DeepSeek-V3/R1，支持 provider/model 前缀自动剥离
- 修复 Codex rate-limit 广播事件导致的用量虚增、DSH 增量二次同步重复计费、Roo Code 嵌套 usage 解析与 Agent Health 多路径探测
- 150 个测试全绿

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
