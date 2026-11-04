# AGENTS.md — DSH + Codex 双宿主发布包

本目录是 **demo 发布包**，同时支持 DSH 与 Codex。  
仓库根目录是唯一工作区；不要写到仓库外。

## 入口

### Codex

- 技能：`.agents/skills/`
- 用 `$github-daily-picks` 跑日报/补跑/入库/对比/维护。
- 用 `$tool-stack` 按需求配工具。
- 先读 `README.md`、`QUICKSTART.md`、`PROMPT-daily.md`、`RUBRIC.md`。
- 网络优先当前会话原生 HTTP/网页工具；否则 `gh api` 或经授权的 `curl.exe`。
- 不要假设 DSH 的 `web_fetch`、`present`、`schedule_*` 一定存在。
- 页面被宿主预览屏蔽时，双击 `打开工具库.cmd`，或运行：
  ```powershell
  .\tools\start-site.ps1 -NoOpen
  # http://127.0.0.1:8788/#/daily
  ```

### DSH

- 技能：`.dsh/skills/`
- 使用 `web_fetch`、文件卡片和会话内调度。
- 直接按 `PROMPT-daily.md` 执行；页面用 `index.html` 或文件卡片打开。

## 数据边界

- 本包只有 **15 条 demo 数据**，不含作者真实库、picks、报告、候选积压。
- 不要手工改 `data/projects.jsonl` / `data/events.jsonl` / 生成页面。
- 原始层 → `sync-projects` → `rebuild-page`。
- 评分、术语、日报配额以 `GLOSSARY.md` 和 `RUBRIC.md` 为准。

## 验收

```powershell
& ".\.dsh\skills\github-daily-picks\audit.ps1"
& ".\tools\check-page.ps1"
```

- 发布包 audit 预期：**166 通过 / 2 跳过 / 0 失败**
- check-page 预期：**PASS**
- 不要把“工程测试通过”当成真实日报已发布。
