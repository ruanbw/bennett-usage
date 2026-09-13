# Bennett Usage

macOS 菜单栏常驻的 AI coding 助手 Token 用量统计。Claude Code / OpenAI Codex / Gemini CLI / Qwen Code / OpenCode / Roo Code·Cline / DSH Harness / Oh My Pi / Pi Agent / Antigravity，一个菜单栏图标加一个 Dashboard，全部看清。Cursor / Copilot / Trae 显示安装状态（云端计费，需 API 才能取数）。

![Dashboard](docs/screenshots/dashboard.png)

## 功能

- **菜单栏速览**：常驻显示今日 Token，点击弹出今日用量、预估费用、各工具分布，一键立即同步。
- **Dashboard**：24 小时 / 今日 / 7 天 / 30 天 / 过去一年 / 按年查看；小时级 Token 趋势（按模型堆叠，柱状 / 折线可切）；工具消耗占比、模型消耗占比；年度热力图（日历 / 月趋势可切）；项目排行；缓存命中统计。
- **设置**：通用（语言、自动刷新频率）、Agent 状态（是否已安装、立即重扫）、计价与汇率（USD / CNY、自定义汇率）、数据与存储（数据库位置、一键清空）、关于。
- **13 个数据源**：本地解析各工具会话记录，无需 API Key，纯本地 SQLite 存储，FSEvents 文件监听自动同步（Cursor / Copilot / Trae 为云端计费，仅检测安装状态）。
- **中英双语**：简体中文 / English / 跟随系统。

![菜单栏弹窗](docs/screenshots/popover.png)

![设置](docs/screenshots/settings.png)

## 安装

1. 从 [Releases](../../releases) 下载 `BennettUsage-<版本>.dmg`。
2. 打开 DMG，把 `Bennett Usage` 拖进 Applications。
3. 首次启动用右键 → 打开（未经过 Apple 公证，右键打开一次即可，以后正常双击）。

要求 macOS 14+，Apple Silicon / Intel 均可。

## 从源码构建

```sh
swift build -c release
./scripts/package-dmg.sh   # 输出 dist/BennettUsage-<版本>.dmg
```

## 数据来源

| 工具 | 默认路径 | 说明 |
| --- | --- | --- |
| Claude Code | `~/.claude/projects` | JSONL transcript，按 `message.id` 去重 |
| OpenAI Codex | `~/.codex/sessions` | rollout JSONL 的 `token_count` 事件 |
| Gemini CLI | `~/.gemini/tmp` | session JSONL |
| Qwen Code | `~/.qwen/tmp`（`QWEN_HOME` 可改） | Gemini 分叉，同格式 |
| OpenCode | `~/.local/share/opencode` | `opencode.db`，老版本走 `storage/message` |
| Roo Code·Cline·Kilo | VSCode `globalStorage/*/tasks` | `api_conversation_history.json` |
| DSH Harness | `~/.dsh/sessions`（`DSH_HOME` 可改） | `session.v3.jsonl.zstd`，无 zstd 时回退 projcache |
| Oh My Pi | `~/.omp/agent/sessions` | 另支持 `~/.omp/stats.db` |
| Pi Agent | `~/.pi/agent/sessions` | |
| Antigravity | `~/.gemini/antigravity/conversations` | |
| GitHub Copilot | `~/.copilot` | 仅检测安装，token 需 GitHub API |
| Cursor | `~/Library/Application Support/Cursor` | 仅检测安装，token 需 Dashboard API |
| Trae | `~/.trae` | 仅检测安装，云端计费 |

数据库在 `~/Library/Application Support/BennettUsage/usage.db`，删掉即清零重算。

常用启动参数：`BennettUsage.app/Contents/MacOS/BennettUsageApp --dashboard`（直接打开 Dashboard）。

## 计价

内置各模型单价，按输入 / 输出 / 缓存读 / 缓存写分别计价，汇总为 USD，可一键切换 CNY（汇率自定义）。价格表随模型变化会有滞后，费用为估算值。

## 隐私

所有解析和存储都在本机完成，不上传任何数据。

## 版本日志

见 [CHANGELOG.md](CHANGELOG.md)。

## License

MIT，见 [LICENSE](LICENSE)。
