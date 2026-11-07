# 联网与查询执行

RepoDossier v1.3.0。页面可离线阅读；生成新日报需要公开GitHub数据、有效认证、完整证据和审阅。缺条件时保留未完成状态。

## 认证、网络与额度

统一读取当前进程 `GITHUB_TOKEN`、`DSH_GITHUB_TOKEN`、`GH_TOKEN`，再尝试既有gh登录及显式启用的既有Git登录。Git读取为非交互模式、10秒上限，不打开登录窗口；没有凭据时提前停止。既有Git登录复用由 `config.json` 中 `sources.reuse_git_login` 控制。

token只在内存和发往 `api.github.com` 的请求头中使用，不打印、不写日志或命令参数，不发给镜像。需要初次登录时由用户在自己的终端完成，不把token粘到对话里。

`sources.daily_api_ceiling=45` 为匿名兼容档；`authenticated_daily_api_ceiling=180` 为认证档。两档共用工作区请求账，180是项目预算，不能替代官方响应头限流。默认 `require_auth_for_daily=true`，不静默退回匿名扫完整日报。

GitHub普通接口与搜索分别限流；认证普通接口通常5000次/小时，仓库搜索30次/分钟。官方的secondary限制仍可能触发，按 `Retry-After`、`X-RateLimit-Reset` 等响应头暂停；不轮换陌生出口或token池绕过限制。[官方额度](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)、[搜索额度](https://docs.github.com/en/rest/search/search#rate-limit)。

请求先预占、后追加结算。仅HTTP 0、curl 5/6/7且无源站收据的明确未连通尝试退回预算；HTTP错误、304、TLS错误、不明超时与中断均保守计入。首次网络失败停止整队，同路径共享60秒冷却，避免逐项目空试。

代理优先级：显式参数 → `DSH_HTTP_PROXY` → `HTTPS_PROXY` → `HTTP_PROXY` → `ALL_PROXY`；没有配置则直连，`-NoProxy` 明确禁用继承代理。宿主权限由宿主管理，脚本不能赋予网络许可。

## 日常入口与补证恢复

```powershell
pwsh -NoProfile -File tools/daily-network.ps1 -Action Status
pwsh -NoProfile -File tools/daily-network.ps1 -Action Collect -Date YYYY-MM-DD
pwsh -NoProfile -File tools/daily-network.ps1 -Action Readmes -Batch data/audit/reviews/<包目录>
```

Status不发HTTP。Readmes在同包、共享日预算内，累计最多等待30分钟后继续；认证、网络、预算或等待上限造成停止时保留断点。只执行本包对应task IDs，不把同项目历史任务一起重抓。

`check-daily-network.ps1 -Live` 用一次公开GET实测认证；可选 `-Mirrors` 对固定公开地址做无凭据HEAD，`-NoProxy` 检查直连。不从一次成功推断全国可用，不把凭据可读等同于已验证认证。

## 查询不能由模型临场缩减

2026-11-07起，计划生成和覆盖核查共用 `query-contract.ps1`，从 `data/queries.json` 重新计算应跑入口。删Q、改可选、擅改页数、每页数量或条件，不能通过核查。Q1b、周六Q8按既有频率必跑；Q3s只有基于成功Q3的实际结果确认未触发，才合法跳过。手动或disabled通道不计作已自动运行。

Import绑定计划SHA、准确Q编号、原URL与动态任务。短缺响应可以保留为部分证据，不能凭它单独宣称该Q完成。覆盖仍是预算抽样，不是GitHub全集覆盖。

`data/runs/<date>.collection-status.json` 保存计划数、成功数、合法跳过和未完成Q。正式页面和发布验收会重新检查，写“不完整”或手写绿色coverage不能过关。宿主没有提供上下文读数时写未知；不能从会话长度猜预算，也不能从一个百分比猜还能跑几条。

## 宿主HTTP的文件模式

本机curl不通而宿主HTTP可用时，继续同一调度器：

1. 运行 `collect-daily.ps1 -Date YYYY-MM-DD -NextRequest`，读取 `data/raw/<date>/r<N>/next-request.json`。
2. **仅退出0且kind=request才发请求**。kind=complete才表示条件已满足；paused/blocked不允许照旧文件重发。
3. 由宿主实际可用的HTTP工具请求准确URL，把完整响应保存到指令给出的 `response_file`。不要打印大JSON、缩小per_page或虚构工具的保存参数；只取得截断文本时保持未完成。
4. 按指令调用 `fetch-daily.ps1 -Date <date> -Round <round> -Import <query> -File <response_file> -RequestUrl <url>`，动态任务再传 `-QueryTask <query_task>`。有真实状态/响应头时可传 `-HttpStatus`、`-HeaderFile`，没有则记录未知。
5. 重复第1步，先取缺少响应的Q，再推进额外页；预占预算对同一待办幂等，成功raw校验复用。换对话仍使用原日期、轮次和文件，不重新开整轮。

宿主认证未知时按匿名本地预算预占。每个工作区同时只安排一个日报执行者；不要在请求尚未返回时让另一个对话重复发送同一待办。

## 镜像边界

- [USTC GitHub Release](https://mirrors.ustc.edu.cn/help/github-release.html)：仅已收录项目的发行文件，多数只保留最新版本。
- [南京大学镜像站](https://mirror.nju.edu.cn/)：部分发行/公开文件；实际网络可达性须另测。
- [Gitee仓库镜像](https://help.gitee.com/repository/settings/sync-between-gitee-github)：指定仓库的分支、标签、提交同步，启用前核实账户和当前产品策略。
- [jsDelivr](https://github.com/jsdelivr/jsdelivr#github)：国际CDN，适合固定完整commit SHA的公开文件，需与官方版本/已知内容hash核对。

这些不是完整GitHub Search镜像，也不能替代实时星数、issue或release事实。尚未部署统一云采集或国内数据分发服务；本版本不保证全国免代理或永久不中断。
