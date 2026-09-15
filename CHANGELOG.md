# Changelog

## Unreleased — 2026-09-16

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
