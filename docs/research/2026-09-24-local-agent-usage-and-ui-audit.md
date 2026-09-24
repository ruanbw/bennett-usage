# 本地 Agent 用量数据源与 UI/UX 调研

> 调研截止日期：**2026-09-24**。本文记录调研截止日的历史现状、证据、建议和未来验收标准。调研时（实施前）尚未实现或宣称实现 Goose、Crush、Continue CLI、Kimi Code、trajectory 或任何 UI 修复；当前 HEAD 已在此后新增 Continue、Goose、Crush 和 Kimi adapters。本次仅同步文档元数据，不改变产品行为。

## 1. 结论、范围与证据纪律

### 1.1 “所有”的可证伪边界

这里的“所有”不是罗列市面上的 AI 产品，而是：**截至截止日期，能同时被一手材料证明满足以下条件的本地产品集合**：

1. 产品或其 agent/CLI 能在用户机器上运行；
2. 一次模型调用、一次 assistant 消息，或可无损恢复的 session 累计值，会在本地持久化 token/cost；
3. 适配器能按请求读取，或能在每次扫描时以持久基线做无损差分；
4. 字段缺失、格式变化或无法证明语义时可以拒绝/降级，而不是猜测。

以下指标明确**不是账本**，不能为了扩大覆盖而混入 token/cost 总量：

- autocomplete 次数、行补全量或订阅额度；
- premium request、credit、prompt 数或 agent step 数；
- 仅存在于云端 dashboard、订阅后台或 API 的聚合；
- 对聊天/代码文本做 tokenizer 得到的估算；
- 终端 UI 的一次性显示、context-window 估算；
- 只有 Markdown 对话、telemetry sample 或云端截图而没有本地 usage payload 的材料。

因此，“所有”是可证伪的：新增产品必须补齐“本地运行 + 本地持久 schema + 请求或无损差分语义 + 脱敏 fixture”闭环；缺少任一项就保持 `defer` 或 `exclude`，不能把 detection-only 写成用量支持。

### 1.2 证据优先级

从高到低采用以下顺序：

1. **官方稳定文档/API**：厂商明确承诺的导出、CLI JSON、schema 或数据目录；
2. **官方发布包及对应源码**：锁定 npm/PyPI/Homebrew 等实际发布物，再回链官方仓库 commit；这是版本化结论的最高可复现证据；
3. **截止日期前的官方仓库当前源码/迁移/fixture**：可证明实现细节，但不等于稳定用户 API，必须做 schema guard；
4. **社区文章、forum、逆向数据库和搜索摘要**：只用于发现路径或风险，不能单独把候选提升为 production adapter。

有冲突时，版本更贴近实际安装物的发布包优先于仓库 README；固定 commit 优先于可变的 `main` 链接；源码中的明确字段语义优先于 UI 文案。若官方材料互相矛盾，文档必须保留版本边界和未知项。

## 2. 实施前 14-source 历史快照（当前 HEAD 状态见下文）

以下表格是调研截止日、四个 adapter 实施前的**历史快照**。当时 `MetricsAggregator.builtInAdapters()` 注册 **14 个 source adapter**：

| 类别 | 数量 | source adapter |
|---|---:|---|
| 本地用量源 | 11 | Pi Agent (`pi`)、Oh My Pi (`omp`)、Claude Code (`claude`)、OpenAI Codex (`codex`)、Gemini CLI (`gemini`)、Antigravity (`antigravity`)、OpenCode (`opencode`)、Roo Code / Cline / Kilo VS Code tasks (`roo`)、Cline desktop/CLI (`cline`)、Qwen Code (`qwen`)、DSH Harness (`dsh`) |
| detection-only | 3 | GitHub Copilot (`copilot`)、Cursor (`cursor`)、Trae (`trae`) |

在这张历史快照中，`copilot`、`cursor`、`trae` 的 adapter 均标记 `isSyncStub = true`：只参与安装检测，不产生 token 记录。仓库 README 对这三项的“云端计费/需要 API”说明与源码一致。其他 11 项虽读取不同版本的本地文件或数据库，但均属于当时已经存在的实现，不表示其上游 schema 永久稳定。

**当前 HEAD（文档对齐时）** 已在此后新增 4 个本地用量 adapter：Continue CLI (`continue`)、Goose (`goose`)、Crush (`crush`) 和 Kimi Code (`kimi`)。因此当前 `AdapterCatalog.defaults` / `MetricsAggregator.builtInAdapters()` 共 **18 个 source adapter**（15 个本地用量源 + 3 个 detection-only）；上表的 14-source 数字仅用于保留实施前历史，不应被读作当前覆盖数。

## 3. 候选决策矩阵

| 候选 | 决策/当前状态 | 本地证据与纳入方式 | 主要原因/限制 |
|---|---|---|---|
| **Goose** | **已实现** | `sessions.db` 的 `usage_ledger` 是逐 provider/model invocation 的持久 ledger；另有 `sessions` 累计值和 `messages.metadata_json` | 没有稳定外键把它等同“用户 turn”；ledger 缺独立 provider/reasoning；需处理 `carried_forward`、父子 session 和数据库替换 |
| **Crush** | **已实现** | 全局 `projects.json` 枚举每项目 `data_dir`，`data_dir/crush.db` 的 `sessions` 保存累计 prompt/completion/cost | 只有 session 累计值，无 cache/reasoning/message usage；时间仅到秒；`cost = 0` 可能是 flat-rate，不等于零消费 |
| **Continue CLI** | **已实现（精确锁定 1.5.47）** | `~/.continue/sessions/*.json` 的 `history[i].message.usage` 保存 assistant-level usage | provider/timestamp/request ID 未保存；fork 与 compaction 无法完全去重；缺 usage 很正常；顶层 `usage` 是累计 checkpoint |
| **Kimi Code** | **已实现（token-only）** | 当前 `$KIMI_CODE_HOME`（默认 `~/.kimi-code`）下 session 的 `agents/<agent-id>/wire.jsonl` 中 durable `usage.record` | 稳定 schema 无 cost/provider/reasoning/request ID；需 token-only 降级；不得沿用旧调研的 `~/.kimi/context.jsonl` |
| **mini-SWE-agent** | **P1；要求显式 trajectory root/output path** | `.traj.json` 的 assistant `extra.cost`、`extra.response.usage`、`extra.timestamp` 可逐调用；运行总成本仅作对账 | 默认 `output_path = nil`，不做全盘发现；provider 原始 usage 随 LiteLLM 变化；trajectory 重写要按内容 hash supersede |
| **SWE-agent** | **P1；要求显式 trajectory root** | 完成态 `.traj` 是可回放历史，可能有运行级 `model_stats` | 不同 trajectory format 的 token 字段不一致；只拿到 run aggregate 时只能做无损累计导入，不能声称逐请求 |
| **OpenHands** | `defer` | 当前顶层 Agent Canvas 使用 `software-agent-sdk`；`~/.openhands` 只证明持久根 | 旧 `base_state.json` 说法已过时；当前 conversation/event/usage schema 与 resume 语义未闭环，先做真实 capture gate |
| **Aider** | `defer` | `.aider.chat.history.md` 是文本历史；`/tokens` 是 context 估算；analytics 是 opt-in telemetry | 默认本地历史没有结构化 provider usage；不能把 website sample、Markdown 或 `/tokens` 当账本 |
| **Amp** | `exclude`（当前版本） | 官方材料证明本地 CLI/thread 能力 | 核心闭源，未取得稳定本地逐请求 token/cost schema；账户 usage 不能替代本地 ledger |
| **Factory Droid** | `exclude`（当前版本） | 官方产品存在 | 无官方或可复现发布源码证明本地 session 的逐请求 usage schema；credits/UI 不够 |
| **Zed** | `exclude`（原生 Agent threads） | 核心部分开源 | 未闭环 Agent thread 数据库的逐请求 usage；托管模型、BYOK、ACP 是不同来源，不能互相推断 |
| **Windsurf Cascade** | `exclude`（当前版本） | 官方产品/文档存在 | 没有本地 Cascade 逐请求 token schema 的一手证明；credit/prompt limit 和云 dashboard 被排除 |
| **GitHub Copilot CLI/IDE agent** | `exclude` 作为 token adapter；保留 detection-only | 当前仓库已有 detection-only adapter | premium request 与云端 billing 不是 token；本地 state/telemetry 未证明有逐请求计费字段 |
| **Amazon Q Developer CLI / Kiro** | `exclude` 新安装；Q legacy 仅观察 | 旧 Q 仓库已停止活跃开发并转向 Kiro CLI | 新 Kiro 闭源；Q `/stats` 跨 restart/resume 的逐请求持久化未证明，不能把旧实现当当前产品 |
| **泛 MCP agents** | `exclude` 作为独立 source family | MCP 标准化工具发现/调用协议 | MCP 不定义模型 token/cost；usage 属于宿主，应由 Claude/Continue/Kimi 等各自 adapter 采集 |

这里的 `defer` 是“等待可复现证据或用户配置”，`exclude` 是“当前没有合格本地账本/不满足产品边界”。二者都不是永久判决；未来拿到新的官方 schema 和真实 fixture 后应重新评审。

## 4. 四个已实现 adapter 的数据契约（历史设计依据）

### 4.1 Goose：`sessions.db` / `usage_ledger`

#### 路径与 schema

权威抽象路径是：

```text
Paths::data_dir() / "sessions" / "sessions.db"
```

macOS 当前默认展开为：

```text
~/Library/Application Support/Block/goose/sessions/sessions.db
```

若 `GOOSE_PATH_ROOT` 是绝对路径，则为：

```text
$GOOSE_PATH_ROOT/data/sessions/sessions.db
```

实现应复现 `Paths::data_dir()`，不要只硬编码某一个 OS。CLI 与 Desktop 在相同用户和 path root 下使用同一核心 `SessionManager`/SQLite；remote backend 的数据库不在本机。

截至 commit `80c1197583cc9dc909b7e010c78b4ad58c81e8ce`（2026-09-23），schema version 16。`usage_ledger` 的关键列为：

```text
id, session_id, created_timestamp, model,
input_tokens, output_tokens, total_tokens,
cache_read_tokens, cache_write_tokens,
cost, cost_source, is_compaction
```

其中 `id` 是全局 `AUTOINCREMENT`。`sessions` 另保存 `provider_name` 和 `accumulated_*`；`messages.metadata_json` 可提供 message usage 与 inference metadata。Goose 的 `Usage` 明确规定 `input_tokens` 已包含 cache read/write，cache 是 input 子集。

#### 增量算法与限制

1. 首次发现数据库时做 schema introspection；必需表/列不匹配就标 unsupported，不宽松读成 0。
2. 逐 ledger 行用稳定键 `(database_instance_id, usage_ledger.id)` 去重；不能用 `(session_id, timestamp, model, total_tokens)`，同秒同值可合法重复。
3. 后续只读 `id > watermark`；忽略 `cost_source = 'carried_forward'` 作为新使用量。
4. 首扫对账要复刻官方的 `max(sessions.accumulated_*, SUM(usage_ledger.*))`。若 legacy accumulated 高于真实 ledger，可用一条明确标记的 baseline gap 记录补齐；不能把 accumulated、ledger SUM 和 `carried_forward` 相加。
5. session 总计需递归包含父子 session 树并对每 session 先取 `max(accumulated, ledger_sum)`，避免父子重复；逐调用 ledger 仍应保留自己的 `session_id`。
6. 检测数据库文件身份、schema fingerprint、`max(id) < watermark`；发生替换/回退时重建 database instance watermark。
7. 限制：ledger 行不是明确 user turn；没有稳定 ledger-to-message 外键；provider 只能从 session 上下文补充，不能声称逐调用精确；没有规范 reasoning token 列。

### 4.2 Crush：全局 `projects.json` + 每项目 `.crush/crush.db`

#### 路径与 schema

全局配置根按平台为：

```text
CRUSH_GLOBAL_DATA/crush.json
$XDG_DATA_HOME/crush/crush.json
%LOCALAPPDATA%/crush/crush.json       # Windows
$HOME/.local/share/crush/crush.json  # 其他 Unix
```

项目注册表是全局配置目录旁的 `projects.json`，核心映射为：

```json
{
  "projects": [
    {
      "path": "/absolute/project/path",
      "data_dir": "/absolute/project/path/.crush",
      "last_accessed": "2026-09-24T12:34:56Z"
    }
  ]
}
```

每项目数据库为 `<data_dir>/crush.db`；默认就是 `<project-root>/.crush/crush.db`，但 `--data-dir`/配置可改变。`sessions` 关键累计列为：

```text
id, parent_session_id, message_count,
prompt_tokens, completion_tokens, cost,
created_at, updated_at
```

`messages` 可补充 `model`、`provider`、`created_at`、`finished_at`，但**没有** message-level token/cost、cache 或 reasoning usage 列。

#### 增量算法与限制

1. 从 `projects.json` 枚举唯一 `data_dir`，以规范化 DB 路径建立 `databaseKey`；对每个 `data_dir/crush.db` 使用 SQLite read-only URI + `query_only=ON`，不运行 migration、不修改 WAL/journal。
2. 首次扫描保存每个顶层 session（默认 `parent_session_id IS NULL`）的完整累计 snapshot 和 baseline。ID 应包含 DB path hash + session ID + generation，不能只用 session UUID。
3. 后续用 `updated_at >= last_updated_at` 取候选；因为只有秒级时间，不能用严格 `>`。对每个 session 比较 prompt/completion/cost 累计值并输出差分。
4. 任一累计值下降时不得产生负 delta；增加 generation，以当前完整值作为新 baseline。记录 DB file identity/schema fingerprint，数据库替换时全量重建。
5. 无删除 tombstone，单靠 cursor 无法发现 session 删除；需周期性全量扫描。零变化不生成记录。
6. 限制：只能得到 session 累计差分，不能声称逐请求；`updated_at` 不是 usage event time；flat-rate 下 `cost = 0` 不代表无 token；`EstimatedUsage` 标记没有持久化；project 只能通过 `data_dir` 映射，匹配不到时保留 DB 路径而不猜 project。

### 4.3 Continue CLI：1.5.47 的 `history[i].message.usage`

#### 路径与 schema

`@continuedev/cli` 的截止日 npm `latest` 是 **1.5.47**（`gitHead d3f60ba9dd3fb5bfd3c91d6fbb41ce1aa768db45`）。生产默认路径：

```text
~/.continue/sessions/<uuid>.json
```

`CONTINUE_GLOBAL_DIR` 可指定 global dir；相对路径依赖 Continue 进程启动 cwd，外部采集器不能可靠还原，所以应支持用户显式给出绝对路径。

顶层 session 的 `usage` 是累计 checkpoint。逐 assistant usage 的准确位置是：

```text
history[i].message.usage
```

典型 1.5.47 字段为：

```text
prompt_tokens
completion_tokens
total_tokens
prompt_tokens_details.cache_read_tokens | cached_tokens
prompt_tokens_details.cache_write_tokens
completion_tokens_details.reasoning_tokens        # 可选、provider-specific
model
cost_cents                                      # CLI 估算并按分舍入
```

#### 增量算法与限制

1. 扫描 `<globalDir>/sessions/*.json`，排除 `sessions.json`；校验 UUID 文件名和 JSON `sessionId`。
2. 先用 size/mtime/inode 快速跳过；文件有变化时计算完整 SHA-256，避免粗粒度 mtime 漏扫。
3. 逐 `history` index 处理 `role == assistant` 且 `message.usage` 存在的项。record ID 基于 `sessionId + historyIndex + assistant semantic identity`，usage payload fingerprint 单独计算；同一 item 的 usage 补全应 upsert/correct，而不是生成第二笔。
4. 重复扫描相同内容不新增；JSON 正在覆盖或尾行/文件暂时无效时不推进 checkpoint，进入 retry/quarantine。
5. 不因 compaction、session 删除或 `/clear` 自动减记已发生 usage；如产品需要文件 mirror，应另设 tombstone，不能和 append-only 消费账本混用。
6. 限制：没有可靠 provider、request timestamp、request ID；文件 mtime 只能叫 `sourceModifiedAt`，不能伪装请求时间。fork 复制 history 而新 session 累计归零，且无 `forkedFromSessionId`，无法完全消歧；缺 usage 的 assistant 不生成记录；`cost_cents` 是 CLI 估算，不是 provider 账单。

### 4.4 Kimi Code：当前 `wire.jsonl` 的 durable `usage.record`（token-only）

#### 路径与 schema

当前官方 Kimi Code 数据根是：

```text
$KIMI_CODE_HOME                 # 默认 ~/.kimi-code
```

session 记录形态为：

```text
$KIMI_CODE_HOME/sessions/<workDirKey>/<sessionId>/agents/main/wire.jsonl
$KIMI_CODE_HOME/sessions/<workDirKey>/<sessionId>/agents/<agent-id>/wire.jsonl
```

稳定的 durable event 是 `type: "usage.record"`，序列化后包含事件基类补充的 `time`，schema 为：

```json
{
  "type": "usage.record",
  "time": 1730000000000,
  "agentId": "agent-0",
  "model": "kimi-for-coding",
  "usage": {
    "inputOther": 123,
    "output": 45,
    "inputCacheRead": 678,
    "inputCacheCreation": 9,
    "raw": {}
  },
  "usageScope": "turn"
}
```

`raw` 是 provider-specific 可选数据，不是跨 provider 统一 schema。**纠错：旧调研中的 `~/.kimi/context.jsonl` 是过时说法；当前官方文档和源码均指向 `~/.kimi-code/**/wire.jsonl`。**

#### 增量算法与限制

1. 递归扫描 session 下 `agents/**/wire.jsonl`；按 `(canonical file path, file generation/inode)` 保存 byte offset/line index，容忍最后一行尚未写完。
2. 对 `usage.record` 计算 canonical payload hash；记录键至少包含 file generation + byte offset/line index + payload hash。不能用 model/token/time 组合去重，因为合法重复调用可完全相同。
3. 检测 truncation/rewrite；若 inode、长度前缀或文件 hash 表明 generation 改变，重扫该文件并用 supersede/tombstone 语义处理，不能把旧新内容相加。
4. 映射 `inputOther → fresh input`、`output → output`、`inputCacheRead/creation → cache`；时间使用事件 `time`。
5. **只支持 token-only。** 稳定 schema 没有 cost、provider、reasoning、request/trace ID；不从 model 名称猜 provider，不从 `raw` 猜 reasoning，不用本地价目表伪造 source cost。缺失 usage 的事件不生成记录。

## 5. 统一 token/cost 口径

`UnifiedTokenRecord.totalTokens` 的当前定义是：

```text
inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
```

因此 adapter 必须把 `inputTokens` 定义为 **fresh input**：

- provider 明确给出已拆分的 input-other + cache read + cache write：直接映射；
- provider 的 input 已包含 cache，但另有 cache read/write：`freshInput = providerInput - cacheRead - cacheWrite`，并验证非负；
- provider input 与 cache 的包含关系未说明：保留 raw usage/诊断，不能随意相减或相加；
- Kimi 的 `TokenUsage` 已把输入拆为 `inputOther/inputCacheRead/inputCacheCreation`，不应再次加 cache；
- 只有在拆分后，`fresh + output + cacheRead + cacheWrite` 才可与 provider `totalTokens` 对账；相等才证明没有重复。

硬规则：

1. provider 明确返回 0 才是 0；字段缺失是 unknown/null/不生成该 usage record，绝不能伪造 0；
2. cache/reasoning 只有 schema 明确时才写，provider-specific `raw` 不能未经版本 guard 提升为统一字段；
3. provider-reported cost、CLI/产品估算和本地定价估算必须区分来源；本轮 Kimi 只能 token-only；
4. 若当前持久模型把部分维度定义为非 optional，实施前应先用独立提交把“unknown”与真实 0 分离，而不是在 adapter 中偷偷补 0；
5. session 累计差分、ledger 明细和 trajectory 总计只能选一个权威增量口径，另一个用于对账，不能双记。

## 6. 源码审计确认的 UI/UX 问题

本节是调研时源码审计的历史问题清单；当前 HEAD 已实现其中多项修复，尚未完成的项目以第 8 节为准。尚未做 GUI/VoiceOver 实测的性能或时序项明确标为风险/验收项。

### P1：可信度与可访问性

1. **清空记录语义与通知不一致。** `SettingsContentView` 使用 `try? await clearAllRecords()`，没有进度、按钮禁用或成功/失败反馈；实现删除 `unified_token_records`、`daily_rollups`、`sync_cursors`，但源日志仍在，下一次 FSEvents/heartbeat/sync 会重新导入。界面“永久删除”文案因此过度承诺；成功后也没有明确发布统一 data update，已打开 Dashboard/Popover 可保留旧值。产品必须二选一：明确叫“清空本地统计缓存”（以后会从源恢复），或实现 source suppression/cutoff 才称持久删除；两者都要通知所有消费者并显示结果。
2. **币种/汇率变更不具可观察性。** `PricingEngine` 是普通 final class，setter 写锁和 `UserDefaults`，但不是 `ObservableObject`、不发 `objectWillChange`/设置通知；Dashboard 和 Popover 直接调用 formatter。已打开界面可能在下一次数据 summary 前继续显示旧币种。需建立单一可观察 settings 状态并让所有费用消费者订阅。
3. **热力图不是完整无障碍交互单元。** 日期 cell 固定 `11×11`，只用 `.onTapGesture`、`.onHover`、`.help`，没有 `Button`、日期 `accessibilityLabel`、token/cost `accessibilityValue` 或 selected trait；趋势图也主要依赖 hover。应让日期可聚焦/可操作，label 与 value 分离，选中状态同时用 trait 和非颜色视觉线索。
4. **小字号 tertiary 文本对比度不足。** 浅色 `#86868B` 对白底约 3.5:1，深色 `#636366` 对 `#262629` 约 2.5:1，却用于 caption/axis/rank 普通文本。常规小字应至少 4.5:1；实际前景色/表面组合需覆盖 light/dark/high contrast。
5. **24 小时/今日项目排行无界。** 两处 query 使用 `limit: .max`；全部项目先在 SQL 排序并在 Swift 合并，展开后进入 eager `VStack`/`ForEach`。需 SQL Top N、独立 count、`LazyVStack` 或分页，并在大项目数据集测量。
6. **当前年度活跃日分母误导。** heatmap 只到今天，但 `fetchAnnualSummary` 的 `totalDays` 始终是完整 365/366，UI 直接算 `activeDays/totalDays`。当前年应使用 year-start 到 today 的已过天数，文案明确“今年至今”；历史年仍用全年。
7. **过去一年不可达。** analytics 和趋势支持 `.pastYear`，README 也列出该范围，但 Dashboard 顶部仅提供 24h、today、7d、30d 和年视图，没有设置 `.pastYear` 的入口。窄宽度可用 `ViewThatFits` 在完整按钮与 Menu 间降级，不能删功能。
8. **中文界面仍有硬编码英文/美元。** Settings 中可见 `SQLite Database`、`records`、`100% Local-First & Private`、`Open Source` 等；日详情 localization 两语都固定 `Cost: $`/`费用: $`，与可配置 CNY 冲突。需把可见字符串移入 localization key，并统一由 PricingEngine 格式化。

### P2：布局、冗余查询与性能测量

1. **响应式布局不足。** Dashboard 最小 960×680、Settings 750×510，多个关键区域是固定 `HStack`，源码没有 `ViewThatFits` 或窄宽度/大字体替代。需对最小、常见、宽屏、最大辅助字体做布局验证。
2. **unused all-time SUM。** Dashboard 每次刷新执行 `loadAllTimeData()`，查询 `fetchAllTimeTotals`；`allTimeTotals` 被赋值但 UI 没有消费者。无过滤时是对 `unified_token_records` 的全表 `SUM`。若产品不展示就删除状态/查询；若展示则应使用 rollup/持久汇总，不保留无收益全表扫描。
3. **冷启动和刷新缺少性能基线。** 数据库在 `app.run()` 前同步初始化，随后启动 watcher 和全部 adapter 同步；源码已有 WAL/cache/rollup cache、SQL 下推和通知 throttle 等良好基础，但现有 view tests 多只检查 `body != nil`，没有 XCUITest、clock/memory metric 或 accessibility audit。应按“测量 → 找因 → 修复 → 重测”记录同一数据集的 Release trace，而不是先凭感觉重构。
4. **UI 测试覆盖不足。** 没有 UI Testing target，现有测试捕获不到币种不刷新、clear 后重导入、热力图键盘不可达、固定布局和同步重导入。最低限度应增加 UI/集成回归与 Accessibility Inspector + VoiceOver/Full Keyboard Access 人工验收。

## 7. Apple 官方指南映射

- [ViewThatFits](https://developer.apple.com/documentation/swiftui/viewthatfits) 按实际可用约束选择第一个能放下的候选布局，适合时间范围控件在完整按钮组和 Menu 之间降级，而不是改变功能状态。
- [Button](https://developer.apple.com/documentation/swiftui/button) 提供标准可聚焦/可激活语义；热力图可点击日期应优先使用 Button，而不是给色块附加 tap gesture。
- [`accessibilityLabel`](https://developer.apple.com/documentation/swiftui/view/accessibilitylabel(_:)) 表达“这是什么/包含什么”，[`accessibilityValue`](https://developer.apple.com/documentation/swiftui/view/accessibilityvalue(_:)) 表达当前值；[`AccessibilityTraits.isSelected`](https://developer.apple.com/documentation/swiftui/accessibilitytraits/isselected) 表达选中状态。日期、数值、selected 不应只靠颜色或 tooltip。
- [Accessibility HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility) 与 [Accessibility Inspector](https://developer.apple.com/documentation/accessibility/accessibility-inspector) 支持的 WCAG AA 基线是：17 pt 及以下普通文本 4.5:1，18 pt 及以上或任意字号 bold 可用 3:1。实际验收要测文字与真实背景，而不是只看调色板原色。
- [Settings HIG](https://developer.apple.com/design/human-interface-guidelines/settings) 和 [SwiftUI Settings](https://developer.apple.com/documentation/swiftui/settings) 描述 macOS 的标准 Settings window、App menu/`Command-,`、pane/toolbar 和最近 pane 恢复；长期通用设置不应只作为 Dashboard 的临时 sheet。
- [Demystify SwiftUI performance（WWDC23）](https://developer.apple.com/videos/play/wwdc2023/10160/)、[Instrumenting your app](https://developer.apple.com/documentation/xcode/instrumenting-your-app) 与 [Time Profiler](https://developer.apple.com/documentation/instruments/time-profiler) 支持先观察 `body` 更新/长 view body，再以同一 Release build 和数据集修复、复测。Apple 没有为项目数、FPS 或列表规模给出通用硬阈值，本项目需用自己的基线设门禁。

## 8. 未完成项与验收

以下仅保留当前 HEAD 尚未完成的计划。已实施的四个 adapter 以及已完成的相关 UI/性能修复不再列入未来计划；未完成项仍按独立提交边界验收。

| 顺序 | 提交边界 | 验收标准 |
|---:|---|---|
| 1 | `refactor: distinguish unknown token usage from zero` | schema migration/模型允许 unknown；missing usage fixture 生成 0 条账本记录；fresh input + cache 拆分 fixture 证明 `totalTokens` 不重复；unknown、provider zero、cost source 各有测试 |
| 2 | `test: finish macOS UI coverage and accessibility matrix` | `swift test` 与 UI/集成回归通过；Accessibility audit 和 manual VoiceOver/Full Keyboard Access 矩阵通过；补齐尚未覆盖的固定布局、同步重导入和性能/时序验证 |

最终发布 gate：已实施 adapter 的 golden fixtures 与真实本地两轮运行对账；重复同步无增量；数据库仍在运行时无写锁/WAL 撕裂；缺 usage 不产生 0；费用来源明确；UI 性能/无障碍问题关闭或明确记录为 blocker。

## 9. 最有价值的官方 URL

以下均为官方文档、官方仓库或固定发布包；正文中的产品结论应优先回到这些一手材料复核。

### 本地 agent / CLI

1. [Goose 官方仓库](https://github.com/aaif-goose/goose)
2. [Goose `SessionManager` 固定 commit 源码](https://raw.githubusercontent.com/aaif-goose/goose/80c1197583cc9dc909b7e010c78b4ad58c81e8ce/crates/goose/src/session/session_manager.rs)
3. [Goose `Usage` 固定 commit 源码](https://raw.githubusercontent.com/aaif-goose/goose/80c1197583cc9dc909b7e010c78b4ad58c81e8ce/crates/goose-provider-types/src/conversation/token_usage.rs)
4. [Crush 官方仓库](https://github.com/charmbracelet/crush)
5. [Crush `projects.json` 注册逻辑](https://raw.githubusercontent.com/charmbracelet/crush/main/internal/projects/projects.go)
6. [Crush SQLite migrations](https://github.com/charmbracelet/crush/tree/main/internal/db/migrations)
7. [Continue 官方仓库](https://github.com/continuedev/continue)
8. [Continue CLI 1.5.47 发布包 session writer](https://unpkg.com/@continuedev/cli@1.5.47/src/session.ts)
9. [Continue CLI 1.5.47 streaming usage writer](https://unpkg.com/@continuedev/cli@1.5.47/src/stream/streamChatResponse.ts)
10. [Kimi Code 官方仓库](https://github.com/MoonshotAI/kimi-code)
11. [Kimi Code Data locations](https://moonshotai.github.io/kimi-code/en/configuration/data-locations.html)
12. [Kimi Code `UsageRecord` 源码](https://raw.githubusercontent.com/MoonshotAI/kimi-code/main/packages/agent-core-v2/src/agent/usage/usageOps.ts)
13. [mini-SWE-agent 官方仓库](https://github.com/SWE-agent/mini-swe-agent)
14. [SWE-agent trajectory 文档](https://swe-agent.com/latest/usage/trajectories/)
15. [OpenHands 官方仓库](https://github.com/OpenHands/OpenHands)
16. [OpenHands software-agent-sdk](https://github.com/OpenHands/software-agent-sdk)
17. [Aider 官方仓库](https://github.com/Aider-AI/aider)
18. [Amp manual](https://ampcode.com/manual)
19. [Factory 官方站点](https://factory.ai/)
20. [Zed 官方仓库](https://github.com/zed-industries/zed)
21. [Windsurf 官方文档](https://docs.windsurf.com/)
22. [GitHub Copilot CLI 官方文档](https://docs.github.com/en/copilot/concepts/agents/about-copilot-cli)
23. [Amazon Q Developer CLI 官方仓库](https://github.com/aws/amazon-q-developer-cli)
24. [Model Context Protocol 官方仓库](https://github.com/modelcontextprotocol/modelcontextprotocol)

### Apple

25. [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines)
26. [Accessibility HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility)
27. [Charts HIG](https://developer.apple.com/design/human-interface-guidelines/charts)
28. [Layout HIG](https://developer.apple.com/design/human-interface-guidelines/layout)
29. [Pickers HIG](https://developer.apple.com/design/human-interface-guidelines/pickers)
30. [Settings HIG](https://developer.apple.com/design/human-interface-guidelines/settings)
31. [`ViewThatFits`](https://developer.apple.com/documentation/swiftui/viewthatfits)
32. [`accessibilityLabel(_:)`](https://developer.apple.com/documentation/swiftui/view/accessibilitylabel(_:))
33. [`accessibilityValue(_:)`](https://developer.apple.com/documentation/swiftui/view/accessibilityvalue(_:))
34. [`AccessibilityTraits.isSelected`](https://developer.apple.com/documentation/swiftui/accessibilitytraits/isselected)
35. [SwiftUI `Settings`](https://developer.apple.com/documentation/swiftui/settings)
36. [Demystify SwiftUI performance（WWDC23）](https://developer.apple.com/videos/play/wwdc2023/10160/)
37. [Instrumenting your app](https://developer.apple.com/documentation/xcode/instrumenting-your-app)
38. [Accessibility Inspector](https://developer.apple.com/documentation/accessibility/accessibility-inspector)
