<h1 align="center">
  <img src="docs/icon.png" width="96" alt="Bennett Usage icon"><br>
  Bennett Usage
</h1>

<p align="center">
  <strong>Token usage for every AI coding agent you run — one menu bar item, one dashboard.</strong>
</p>

<p align="center">
  <a href="https://github.com/ruanbw/bennett-usage/releases/latest"><img src="https://img.shields.io/github/v/release/ruanbw/bennett-usage?label=release" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/arch-Apple%20Silicon%20%7C%20Intel-lightgrey" alt="Apple Silicon and Intel">
  <img src="https://img.shields.io/badge/data-100%25%20local-brightgreen" alt="100% local">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT"></a>
</p>

<p align="center">
  <a href="README.zh-CN.md">简体中文</a> · <strong>English</strong>
</p>

---

A macOS menu bar app that aggregates token usage across **18 AI coding tools**: Claude Code, OpenAI Codex, Continue CLI, Gemini CLI, Goose, Crush, Kimi Code, Qwen Code, OpenCode, Roo Code / Cline / Kilo (VS Code extensions), Cline (desktop & CLI), DSH Harness, Oh My Pi, Pi Agent, and Antigravity. Cursor, GitHub Copilot, and Trae are detected as installed (they bill in the cloud, so token counts need an API).

Everything is parsed from local session stores — no API keys, no accounts, no data leaves your Mac.

![Dashboard](docs/screenshots/dashboard.png)

## Features

- **Menu bar at a glance** — today's tokens always visible; click for today's usage, estimated cost, and a per-tool breakdown, plus one-click sync.
- **Dashboard** — 24 hours / today / 7 days / 30 days / past year / by year. Hourly token trend stacked by model (bar or line), spend share by tool and by model, annual heatmap (calendar or monthly trend), project leaderboard, and cache hit statistics.
- **Settings** — General (language, refresh interval, automatic update checks), Agents (installed or not, rescan now), Pricing & FX (USD / CNY, custom rate), Data & Storage (database location, reset), About (check for updates).
- **Update checks** — compares against GitHub Releases, automatic (once a day, can be turned off) or manual. New versions surface in the menu bar icon and popover, with the DMG for your architecture and an option to skip a version.
- **18 data sources** — local session logs parsed directly. No API keys, plain SQLite storage, FSEvents file watching for automatic sync.
- **English & Simplified Chinese** — or follow the system language.

![Menu bar popover](docs/screenshots/popover.png)

![Settings](docs/screenshots/settings.png)

## Install

1. Download the DMG for your architecture from [Releases](../../releases):
   - Apple Silicon (M-series): `BennettUsage-<version>-arm64.dmg`
   - Intel: `BennettUsage-<version>-x86_64.dmg`
   - Not sure, or want one build for both: `BennettUsage-<version>-universal.dmg`
2. Open the DMG and drag `Bennett Usage` into Applications.
3. On first launch, right-click the app and choose **Open** — it is not notarized by Apple, so this is needed once. Double-clicking works normally afterwards.

Requires macOS 14 or later, on Apple Silicon or Intel.

## Build from Source

```sh
swift build -c release
swift test                          # run the test suite
./scripts/package-dmg.sh            # builds arm64, x86_64 and universal DMGs
./scripts/package-dmg.sh 1.6.1      # pin the version number
./scripts/package-dmg.sh 1.3.0 --only universal   # just one variant
# outputs dist/BennettUsage-<version>-<arch>.dmg and dist/SHA256SUMS.txt
```

Any Mac can cross-compile both slices, so an Intel host still produces the arm64 and universal artifacts.

## Data Sources

| Tool | Default path | Notes |
| --- | --- | --- |
| Claude Code | `~/.claude/projects` | JSONL transcripts, deduplicated by `message.id` |
| OpenAI Codex | `~/.codex/sessions` | `token_count` events in rollout JSONL |
| Continue CLI | `~/.continue/sessions` | per-assistant usage in session JSON; absolute `CONTINUE_GLOBAL_DIR` can relocate the store |
| Gemini CLI | `~/.gemini/tmp` | session JSONL |
| Qwen Code | `~/.qwen/tmp` (override with `QWEN_HOME`) | Gemini fork, same format |
| Kimi Code | `~/.kimi-code/sessions` (override with `KIMI_CODE_HOME`) | current `sessions/**/agents/**/wire.jsonl` usage records; legacy `~/.kimi/context.jsonl` is not read |
| OpenCode | `~/.local/share/opencode` | `opencode.db`; older versions use `storage/message` |
| Roo Code · Cline · Kilo (VS Code) | VS Code `globalStorage/*/tasks` | `api_conversation_history.json` |
| Cline (desktop / CLI) | `~/.cline/data/sessions` | per-message assistant `metrics` in `messages.json`; override with `CLINE_DIR` / `CLINE_DATA_DIR` / `CLINE_SESSION_DATA_DIR` |
| DSH Harness | `~/.dsh/sessions` (override with `DSH_HOME`) | `session.v3.jsonl.zstd`, falls back to projcache without zstd |
| Crush | `~/Library/Application Support/crush` (override with `CRUSH_GLOBAL_DATA`; XDG fallback supported) | reads registered `projects.json` entries and each `data_dir/crush.db` read-only; cumulative top-level session deltas |
| Oh My Pi | `~/.omp/agent/sessions` | also reads `~/.omp/stats.db` |
| Pi Agent | `~/.pi/agent/sessions` | |
| Antigravity | `~/.gemini/antigravity/conversations` | |
| Goose | `~/Library/Application Support/Block/goose/sessions/sessions.db` | read-only SQLite `usage_ledger`; absolute `GOOSE_PATH_ROOT` uses `$GOOSE_PATH_ROOT/data/sessions/sessions.db` |
| GitHub Copilot | `~/.copilot` | install detection only; tokens need the GitHub API |
| Cursor | `~/Library/Application Support/Cursor` | install detection only; tokens need the Dashboard API |
| Trae | `~/.trae` | install detection only; billed in the cloud |

The database lives at `~/Library/Application Support/BennettUsage/usage.db` — delete it to start over from scratch.

Handy launch argument: `BennettUsage.app/Contents/MacOS/BennettUsageApp --dashboard` opens the dashboard directly.

## Pricing

Built-in per-model rates for input, output, cache reads, and cache writes, totalled in USD with a one-click switch to CNY (custom exchange rate). The price table will lag behind new model releases, so treat costs as estimates. Kimi Code's wire records do not report authoritative provider or cost metadata, so its costs come only from this local pricing table and are estimates, not billed amounts.

## Privacy

All parsing and storage happen on your Mac. Nothing is uploaded.

The only outbound request is the update check: one anonymous `GET` to the public GitHub Releases API — no token, no account, and nothing about your usage, projects, or machine in the request. It runs at most once a day and can be disabled in **Settings → General → Check for updates automatically**; with it off, the app makes no network requests at all.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT — see [LICENSE](LICENSE).
