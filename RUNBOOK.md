# 运维手册

## 改时间 / 改频率

按宿主能力管理：

- **Codex**：用户明确要求定时任务时，使用会话提供的 automation 工具；不要只说“改好了”而不实际创建或更新 automation。
- **DSH**：使用 `schedule_*` 定时提醒工具。

当前默认：每天 08:30（Asia/Shanghai）。`config.json` 里的 `schedule` 只是记录，不代表宿主已经创建任务。

## 加一个信息源

1. 在 `SOURCES.md` 表格里加一行，写清完整 URL、取数字段、额度成本；
2. 在 `PROMPT-daily.md` 第 2 步里把它加进执行顺序，并注明失败时是否可跳过；
3. 先在手动跑一次里验证，稳定 3 天后再纳入日常。

**不要**直接改 `PROMPT-daily.md` 的同时改模板——先跑一天看看日报有没有变差。

## 改筛选标准

只改 `RUBRIC.md`。改完在 `reports/index.md` 里没法体现历史差异，所以每次改标准时，在文件顶部加一行变更记录：

```
> 2026-10-15 调整：fork/star 阈值 0.05 → 0.03（漏掉了几个真工具）
```

## 常见故障

| 症状 | 原因 | 处理 |
|---|---|---|
| 日报没生成 | 定时任务未触发 / 宿主未运行 / 会话关闭 | 检查宿主 automation 或 reminder，再手动调用 `$github-daily-picks` 补当天 |
| HTTP 请求超时 | 网络波动、代理或 GitHub 抖动 | 该查询最多重试 1 次；失败记录下来，必跑项未补齐不得发布完整日报。截断 JSON 不算成功 |
| GitHub 403 / 429，API rate limit exceeded | search / core 额度耗尽，或次级限流 | 立即停止本批次；按响应头等待，恢复后只补原轮次缺失项，见下文 |
| 候选数骤降（< 10 条） | 检索式日期变量算错 / 额度耗尽 | 检查 `{D7}` 是否被正确替换；查看 `data/runs/` 里的调用次数 |
| 日报注水（一堆合集） | 排除规则没生效 | 回到 `RUBRIC.md` 第 1 节补规则，而不是在日报里手动删 |
| 重复推荐同一个项目 | 台账没回写 | 检查 `data/seen.jsonl` 是否更新；必要时手动补录 |

## GitHub 限流后的恢复

**默认执行**：`& .\tools\collect-daily.ps1 -Date 2026-10-29`（替换为运行日期）。
首次创建计划，后续复用同轮次；按响应头自动暂停并恢复同一 Q，最多 3 次限流冷却重试，
总等待默认 15 分钟。超出预算退出 2，保留冷却与断点，下次原命令续采。
不要同时启动手写 HTTP 批次；互斥锁只能约束使用这个入口的进程。

**认证**：读取 `GITHUB_TOKEN`、兼容 `DSH_GITHUB_TOKEN` / `GH_TOKEN`，
也支持已安装 GitHub CLI 的 `gh auth login --hostname github.com --web` 登录态。
Token 仅经标准输入传给 curl，不进命令行参数、磁盘配置或运行日志。
只采公开项目，完整返回与 SHA 校验成功才记成功；拒绝截断或 incomplete_results。
建议创建只读公开资源的 fine-grained Token，在本机环境变量设置后重启 Codex，
或由用户完成官方 CLI 登录。`-RequireAuth` 可避免认证失效后退回共享匿名额度。
账号授权需用户本人完成；本地工程不能保证 GitHub 不停机或永不限流。

1. 保留 `data/raw/<日期>/r<N>/plan.json`、`meta.json`、已成功的响应与失败证据；不重建计划、不覆盖成功 raw。先核对 `check-queries.ps1 -Date <日期>` 的实际覆盖情况。
2. 请求保存响应头。收到 403 / 429 后停止所有后续查询；按 `Retry-After` 与额度为零时的 `X-RateLimit-Reset` 等待，没有等待信息则至少等一分钟。重置时间是 UTC epoch 秒，展示给用户时转北京时间。不要连续换工具、换出口重试。
3. 原轮次续采只请求缺失/失败 Q，取回完整 JSON 后使用 `fetch-daily.ps1 -Date <日期> -Round <N> -Import <Q编号> -File <响应文件>` 登记。Q3s 必须在 Q3 成功登记并触发条件后才请求。
4. 必跑项全部成功后，再按 `PROMPT-daily.md` 完成评分、报告与落盘；运行 `check-queries.ps1 -Date <日期>` 和 `run-manifest.ps1 -Date <日期> -Sync`。`check-all` 中历史日期覆盖通过不能证明当天日报已完成。

认证可提高额度：本工作区使用环境变量 `GITHUB_TOKEN`（旧脚本也支持 `DSH_GITHUB_TOKEN`），仅用于请求头，不能写进代码、日志或聊天。匿名仓库搜索上限为 10 次/分钟，认证后为 30 次/分钟；普通 REST 的匿名 60 次/小时、认证 5000 次/小时是另一额度池，实际以响应头为准。代理出口的其他匿名使用者也可能共享 IP 额度。

依据：[GitHub Search 限流](https://docs.github.com/en/rest/search/search#rate-limit)、[GitHub 请求最佳实践](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api#handle-rate-limit-errors-appropriately)。

## 数据门禁的边界（2026-10-24）

- 收工校验只在 `run-manifest -Sync` 里触发；如果当天完全跳过收工，`validate-lib` 不会运行，也不会报警。
- 快照写入器 `append-snapshot.ps1` 只保护“走它写”的行；直接手写 JSONL 仍可能绕过，只能靠收工时 `validate-lib` 拦。
- 手动补救：`tools\validate-lib.ps1`（只读，约 2–3 秒）；红了按输出修，别带着红收工。
- 它只查契约（必填、枚举、日期格式、唯一键），不查语义（漏了仓库、轮次分错不会红）。

## 回滚

- 日报写坏了：日报是独立文件，直接删 `reports/YYYY-MM-DD.md` 并重跑；
- 台账写坏了：`data/seen.jsonl` 每行独立，删掉坏行即可；建议每周复制一份到 `data/backup/seen-YYYY-MM-DD.jsonl`；
- 流程写坏了：`PROMPT-daily.md` 和模板都是纯文本，改回上一版即可；若用 git 管理本目录，可直接 `git diff` 定位。

## 无人值守方案（可选）

2026-11-03：减少日报手动审批采用“宿主自动审批 + 固定联网入口”，设置步骤和权限范围见 [日报权限](docs/daily-permissions.md)。`tools/daily-network.ps1` 只调度既有采集/维护/补证脚本，不替宿主授予权限；先由用户在运行日报的聊天选择 **Approve for me**。工作区写入、评分和标签按已授权流程继续，网络拒绝保留断点，不绕过。代理统一读环境配置，未配置不再假定有 2080 端口。

2026-11-02：每日流程已接入 `tools/daily-maintenance.ps1`，并保留 `fetch-series.ps1` 原入口。宿主触发日报后会按预算刷新和补证，不要求人工逐个调用取证脚本。它没有创建操作系统定时任务或云调度；宿主完全关闭时仍需外部调度器。退出2意味着仍有任务或冷却，不能当作刷新完成。证据状态在 `data/evidence/state.json`，只读核查用 `tools/evidence-queue.ps1 check`，不要手改状态来消红。

本机 PowerShell 的 `.NET` HTTP 通道曾因 schannel 凭证失败而不可用；Codex 会话内可改用原生 HTTP 工具、`gh api` 或经授权的 `curl.exe`。会话型定时任务仍不能保证宿主关闭后运行。真要做到无人值守，需要：

1. 一个可用的代理（`HTTPS_PROXY`）或境外节点；
2. GitHub Personal Access Token（普通 REST 提额到 5000 次/小时；仓库搜索单独限额 30 次/分钟）；
3. 一个外部调度器，调用稳定的 HTTP 客户端完成取数与去重，再启动 Codex 或 DSH 写入日报。

在满足以上条件前，保持会话内手动调用是最可靠的方案。

## 成本

- 每天 3–5 次 GitHub API 调用（匿名），0 元；
- 每天 1 次模型调用（写日报），约几千 token；
- 本地存储：每天 1 个日报文件 + 1 个快照，约 20 KB。
