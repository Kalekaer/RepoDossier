# 数据源与检索式

2026-11-07：官方 API 仍是主源；镜像名单、实测和边界见 [镜像与联网稳定性](docs/network-and-query-reliability.md)。代理按参数/环境选择，不要求其他机器配置 2080。当前工作区要求认证，匿名兼容预算 45/日、认证预算 180/日；连接失败整队暂停，明确未连通的预占会退回。先运行 `daily-network -Action Status` 检查身份与冷却。下文涉及旧机器网络的记录均为注明日期的历史实测。

请求**按宿主能力选择通道**：DSH 优先 `web_fetch`；Codex 优先原生网页/HTTP 工具，没有时使用 `gh api` 或经授权的 `curl.exe`。本机代理（`http://127.0.0.1:2080`）可用：**`curl.exe` 与 Python `urllib` 走代理可达**（2026-10-23 实测 HTTPS 200 / search remaining=10），但普通沙箱会被拒绝，需宿主终端或申请网络权限。**PowerShell 的 `Invoke-RestMethod/-WebRequest`（.NET/schannel）当前实测不通**，不应作为默认 GitHub 通道。**批量/额度**场景才用本机脚本，token 可选（`GITHUB_TOKEN`；旧的 `DSH_GITHUB_TOKEN` 仍兼容）。

## 1. 主源：GitHub Search API

2026-10-29：统一采集器在本轮预算内推进分页与分区。Q2b/c 活跃窗口扩大到 30 天，
固定查询参数保留最多 7 天；先按星数、必要时再按创建时间拆分，广度优先减少单区占用。
Q1b 改为每日；Q9 补无 topic 限制的成熟存量；Q10 补 20–199★ 新项目。
逐查询预算见下表，单轮含重试最多 40 次；未完成范围写入 search-progress 文件。
这是预算采样，固定查询参数也不是 GitHub 的冻结快照；不能保证零漏检。

基址：`https://api.github.com/search/repositories`

日期占位符在运行时替换：`{D7}` = 7 天前，`{D14}` = 14 天前，`{D30}` = 30 天前，格式 `YYYY-MM-DD`。

<!-- QGEN:START -->
| 编号 | 用途 | 检索式（URL 编码后） | 取数 |
|---|---|---|---|
| Q1 | 新星爆发（近 7 天新建） | `q=created:%3E{D7}+stars:%3E150&sort=stars&order=desc&per_page=100` | 100/响应；预算 3 请求 |
| Q1b | 低星新项目（8–30 天，100–499★） | `q=created:{D30}..{D8}+stars:100..499+pushed:%3E{D30}+fork:false+archived:false&sort=stars&order=desc&per_page=100` | 100/响应；预算 2 请求 |
| Q2p1 | 近 30 天新星（800+，第 1 页） | `q=created:%3E{D30}+stars:%3E800&sort=stars&order=desc&per_page=100&page=1` | 100 |
| Q2p2 | 近 30 天新星（800+，第 2 页） | `q=created:%3E{D30}+stars:%3E800&sort=stars&order=desc&per_page=100&page=2` | 100 |
| Q2p3 | 近 30 天新星（800+，第 3 页） | `q=created:%3E{D30}+stars:%3E800&sort=stars&order=desc&per_page=100&page=3` | 100/响应；预算 5 请求 |
| Q2b | 中间星段（200–800★，星数自适应分层） | `q=stars:200..800+pushed:%3E{D30}+fork:false+archived:false&sort=stars&order=desc&per_page=100` | 100/响应；预算 6 请求 |
| Q2c | 中间星段（200–800★，活跃自适应分层） | `q=stars:200..800+pushed:%3E{D30}+fork:false+archived:false&sort=updated&order=desc&per_page=100` | 100/响应；预算 6 请求 |
| Q2d | 实验槽（星速探针） | 见 §1.3（每周三 1 次） | 15 探针 / 出 ≤5 名 |
| Q3 | 方向定向（按星期轮换） | `q=topic:{TODAY_TOPIC}+created:%3E{D30}+stars:%3E200&sort=stars&order=desc&per_page=100` | 100/响应；预算 2 请求 |
| Q3s | 星段兜底 | `q=topic:{TODAY_TOPIC}+stars:200..800+pushed:%3E{D14}&sort=stars&order=desc&per_page=100` | 100/响应；预算 2 请求 |
| Q3b | 实用小工具（cli） | `q=topic:cli+created:%3E{D30}+stars:%3E300&sort=stars&order=desc&per_page=100` | 100/响应；预算 2 请求 |
| Q3c | 第二方向（developer-tools） | `q=topic:{TODAY_TOPIC2}+created:%3E{D30}+stars:%3E200&sort=stars&order=desc&per_page=100` | 100/响应；预算 2 请求 |
| Q4 | 老朋友续热（逐仓库复检） | 逐个 `GET /repos/{OWNER}/{REPO}`，每次最多 5 个 | ≤5 |
| Q5 | 读 README（S 档核实） | 逐个 `GET /repos/{OWNER}/{REPO}/readme`，每次最多 5 个 | ≤5 |
| Q7a | DSH 生态存量补扫（>800★） | `q=dsh+in:name,description+stars:%3E800+pushed:%3E{D30}&sort=stars&order=desc&per_page=100` | 100 |
| Q7b | DSH 生态存量补扫（500–800★） | `q=dsh+in:name,description+stars:500..800+pushed:%3E{D30}&sort=stars&order=desc&per_page=100` | 100 |
| Q7c | DSH 生态存量补扫（200–499★） | `q=dsh+in:name,description+stars:200..499+pushed:%3E{D30}&sort=stars&order=desc&per_page=100` | 100 |
| Q8 | 通用存量（周主题，老但热） | `q=topic:{TODAY_TOPIC}+stars:%3E300+pushed:%3E{D30}&sort=stars&order=desc&per_page=100` | 100/响应；预算 2 请求 |
| Q6 | 备用：聚合检索 | `web_search`（非 GitHub API；失败改用 HN Algolia 等 JSON 源，仅外部讨论信号） | 8 |
| Q9 | 成熟存量（无topic约束） | `q=stars:%3E800+created:<{D30}+pushed:%3E{D180}+fork:false+archived:false&sort=stars&order=desc&per_page=100` | 100/响应；预算 6 请求 |
| Q10 | 低星探索（20–199星） | `q=stars:20..199+created:%3E{D30}+pushed:%3E{D30}+fork:false+archived:false&sort=updated&order=desc&per_page=100` | 100/响应；预算 3 请求 |
<!-- QGEN:END -->

实际 URL 示例（Q1，D7=2026-10-15）：

```
https://api.github.com/search/repositories?q=created:%3E2026-10-15+stars:%3E150&sort=stars&order=desc&per_page=20
```

Search 返回体包含仓库基本事实，但不能代替 README、发行包、供应链等质量证据。
每日基础 10 个查询入口，加周内额外入口及条件 Q3s 最多 13 个；入口数不是请求数，
分页、拆分、失败重试均计入单轮实际请求上限 40。Q2d/Q7 当前 disabled，不能算自动覆盖。

### 1.1 Q2b / Q3s 为什么加（2026-10-18 采纳）

- **Q2b 中间星段**：Q1（7 天新库）和 Q2（30 天 800★+）的头部已被台账占满；10-16 记录 `stars:200..800` 的池子约 **641 条**（⚠️ 与 10-22 同式实测的两万条级不一致，待复核，见 §1.2），头 10 条里 **6 条是新面孔**。Q2b 只要求「近 7 天有推送」，不限创建时间，专门捞「已经有人用、但还没爆」的项目。
- **Q3s 星段兜底**：Q3 的 `created:>{D30}+stars:>200` 在 `docker`（3 条）、`utilities`（0 条）这类小方向会直接空；兜底改为**不限创建时间**、只看 `stars:200..800 + 近 14 天推送`，并保留同一个 `topic`，避免换方向。
- 触发：Q3 结果里**新面孔 <3** 或 `total_count <10` 才加跑 Q3s；Q3 正常时不跑，控制额度。
- 这两条只改**检索式**，不改 `RUBRIC.md` 的筛选/打分标准。

### 1.2 Q2c 为什么加（2026-10-22 用户决定）

- Q2b 的星段 `200..800` 没错，错在 `sort=stars&order=desc` **只取区间顶部**：10-22 同式多次实测池子约 **2 万条**（20,227–20,784，计数会跳），头 15 条是 **11 个 800★ + 4 个 799★**，全是 2015–2022 的老项目；反过来 `order=asc` 则全是 200★，同样贴边。
- Q2c 用**同一星段 + `sort=updated`**：结果沿整个星段铺开（10-22 实测 15 条落在 **200–467★**），能捞到「最近有动静的中段项目」。
- 两条并存、**Q2b 不改不删**：Q2b 看「这段里最成熟的」，Q2c 看「这段里最近最活跃的」。
- 代价：Q2c 会混进「每天推送的大仓库」（KDE / grafana 这类），靠 `RUBRIC.md` 的硬排除与打分筛掉。

### 1.3 Q2d 实验槽（2026-10-22 起，每周三 1 次）

- 目的：给「找还没爆的项目」留一个**可迭代的试验位**，不污染主流程。
- 规则：
  1. 每次只试**一种**新方法，方法池轮换（星速探针 / Hacker News 信号 / 主题桶采样 / 按创建月份切窗）；
  2. 结果**只写** `data/_tmp/q2d-<date>.jsonl` 与运行日志，**不入库、不进 picks、不进日报**；
  3. 连续 **2 周**在同一指标上优于 Q2b/Q2c 基线，才提议转正（改本文件须用户批准）；
  4. 失败 / 无数据照常记录，不阻塞日报。

**方法池（按推荐顺序）**

| 方法 | 怎么做 | 成本 | 已知坑 |
|---|---|---|---|
| 星速探针 | 挑 15 个中段仓库（600–800 / 450–600 / 300–450 / 200–300 各 3–4 个），周三布、下周三收，算 7 日 Δstars/天，取前 5 | 15 次 core / 次 | 样本小、窗口只有 7 天；fork/star<0.02、无 release、0 issue 的先剔除 |
| HN 信号 | Algolia 接口搜 24–48 小时内提到 `github.com` 且 points ≥50 的帖子，抽仓库、过滤到中段 | 1–2 次网页请求 | 英文圈偏科；讨论和涨速高度相关，不能当独立证据 |
| 主题桶采样 | 3–4 个主题各取 5 条中段，拼成一份名单 | 3–4 次 search | 主题选偏就偏；只解决覆盖，不解决「老而不涨」 |
| 创建月份切窗 | 按 `created` 月份切窗口，池子小、没有 800 天花板 | 1–4 次 search | 不是「涨速」信号，只适合当对照 |

**验收（每周三记一次）**

| 指标 | 怎么算 | 门槛 |
|---|---|---|
| precision@5 | 5 个名字里 B 档及以上的比例 | ≥ 0.6 |
| 增量 | Q2b / Q2c 当周结果里没出现过的条数 | ≥ 2 |
| 耗时 | 从开跑到出结论 | ≤ 15 分钟 |

连续 **2 周**都过线 → 提议转正；不过线 → 换下一个方法；两次都不行 → 写进「明确不做」。

### 1.4 可选补充源：HN Algolia（只做「外部讨论」信号）

**不是通用搜索**，只在需要判断「某仓库 / 工具在 Hacker News 上有没有人讨论」时用；不用于发现新工具（发现仍走 Q1–Q5）。

- 端点：`https://hn.algolia.com/api/v1/search_by_date?query={关键词}&tags=story&numericFilters=created_at_i%3E{90 天前时间戳}&hitsPerPage=5`
  - 用 `search_by_date`（按时间），不用 `search`（按相关度，会混进旧帖）
- 命中判定（满足其一才算「有讨论」，否则不算）：
  1. `hit.url` 等于 `https://github.com/{owner}/{repo}`（忽略大小写、末尾斜杠）
  2. `hit.title` 包含完整 `{owner}/{repo}`
- 覆盖范围只有 Hacker News 一个社区，**不得据此说「全网都在讨论」**；未见命中只能写「HN 未见讨论」。
- 通道：宿主可用的网页/HTTP 工具，不占 GitHub 额度；失败 / 限流就放弃，标「未检索到外部讨论」。

**检索能力阶梯（任何任务都按这个顺序，不绑死单一工具）**

| 层 | 通道 | 用途 |
|---|---|---|
| L0 | 宿主 HTTP 工具 + GitHub API | 日报全部检索、仓库事实、发现 |
| L1 | anysearch（**可选**，会话里有才用） | 通用网页检索 / 素材 |
| L2 | 宿主 web search | 通用检索备用；失败重试 1 次即弃 |
| L3 | 宿主 HTTP 工具 + 已知 JSON API（HN Algolia / npm / PyPI / deps.dev） | 讨论信号 / 包事实 |
| L4 | 都没有 | 明说检索了什么、为什么没有；标「未验证」，不编造 |

- 单任务总调用 ≤2 次（含核实）；换通道算一次。
- 所有可用 HTTP 通道整体不可用 = 当天不出日报，只写运行日志——这不是「降级」。

## 2. Q3 方向按星期轮换（已确认的口味）

一天只跑一个方向，避免日报注水；每天轮着来，一周覆盖全。周三、周六额外加跑 Q3b（实用小工具）；**周四额外加跑 Q3c（第二方向）**。

| 星期 | `{TODAY_TOPIC}` | 加跑 |
|---|---|---|
| 周一 | `ai-agent` | — |
| 周二 | `mcp` | — |
| 周三 | `self-hosted` | Q3b `cli` |
| 周四 | `windows` | Q3c `developer-tools` |
| 周五 | `automation` | — |
| 周六 | `developer-tools` | Q3b `cli` |
| 周日 | `llm` | — |

备用方向词池（轮换表跑腻了就换）：`powershell`、`cli`、`devops`、`utilities`、`productivity`、`local-first`、`docker`。

**周四为什么跑两个方向（2026-10-15，用户决定"1A"）**：`windows` 单一方向池子偏小 —— 2026-10-15 实测 `total_count=31`，当天检索结果只有 30 条（周三为 40 条）。当天实测各方向在 `created:>{D30} stars:>200` 口径下的池子：`windows` 31 ｜ `developer-tools` 28 ｜ `local-first` 11 ｜ `productivity` 4 ｜ `docker` 3 ｜ `devops` 1 ｜ `utilities` 0。**选了池子最大的 `developer-tools`**。

> **已知取舍**：`developer-tools` 同时是周六的 `{TODAY_TOPIC}`，两个方向会看到同一批仓库（第二次出现时通常已在台账里，只会进「老朋友动态」）。若觉得重复，两个改法任选：① 把周四 Q3c 换成别的方向（实测备用词池都很小，收益有限）；② 把 Q3c 改成**不带 topic 的宽检索**（`q=created:>{D30}+stars:>200`）——那才是真正能把周四检索结果拉起来的一步，但它不再是"一个方向"，需要另行确认。

「实用小工具」的判定不靠 topic，靠 `RUBRIC.md` 第 2 节的「实用性 + 上手成本」两项——凡是单文件、零依赖、即装即用的，这两项天然得分高。

## 3. 额度与礼仪

| 项 | 匿名 | 有 token |
|---|---|---|
| core | 60 / 小时 | 5000 / 小时 |
| search | 10 / 分钟 | 30 / 分钟 |
| 本方案预算 | 每轮实际请求 ≤40，含失败与重试 | 逐查询另有预算；不绕过限流 |

- **一次跑完，不轮询**。失败就记录并跳过，不重试超过 1 次。
- 记录每次运行的实际调用次数到 `data/runs/`，便于发现额度异常。

## 4. 已排除的源

| 源 | 原因 |
|---|---|
| `github.com/trending` HTML | HTML 抓取易超时，不稳定 |
| `api.ossinsight.io/v1/trends/*` | 官方标注 star 事件数据自 2026-03-01 起不可用，返回空结果 |
| GitHub GraphQL | 匿名不允许（limit 0） |
| 各类第三方 trending 镜像站 | 数据滞后一天以上，无法验证口径 |

## 5. 增速怎么算

官方 trending 的口径拿不到，改用自己的快照：

```
Δstars = 今日 stargazers_count − 最近一次快照中该仓库的 stargazers_count
增速   = Δstars / 间隔天数
```

间隔超过 3 天的快照标记为 `stale`，只做参考、不参与排序。

## 6. README 取数与镜像边界（2026-11-07）

正式审阅统一使用 `fetch-review-readmes.ps1` / `evidence-store.ps1` 的官方 API 证据、版本与已校验缓存。以下 raw/CDN 是公开文件的辅助通道，不是已自动接入的完整备用采集器；不能用一次 HTTP 200 代替内容版本核实或绕开审阅门禁。

| 顺序 | 通道 | 说明 |
|---|---|---|
| ① | `GET /repos/{owner}/{repo}/readme`（`api.github.com`）及同版本有效缓存 | 当前正式补证入口，返回 base64 与官方 blob SHA；按 core 额度、共享预算和冷却执行 |
| ② | `https://raw.githubusercontent.com/{owner}/{repo}/{commitSHA}/{path}` | 已知路径与固定提交下的公开文件；不使用 main/master 猜测来证明版本一致 |
| ③ | `https://cdn.jsdelivr.net/gh/{owner}/{repo}@{commitSHA}/{path}` | 固定完整 commit SHA；与已知官方 blob hash/原始证据核对后才可作为等价内容。国际 CDN 的国内可达性须实测，不传 token；不能以 latest/版本范围的缓存回退冒充新版本 |

**历史故障记录（2026-10-16，并非永久可用性结论）**：`cdn.statically.io`、`raw.githack.com`、`rawcdn.githack.com`、`gitcdn.link`、`r.jina.ai`、`fastly.jsdelivr.net` 曾不可用或重定向；当时 `github.com/.../blob/...` 正文也未完整取得。不将这些未重新验证的通道加入自动重试。jsDelivr 本次样例实测见上述联网文档。

**分支与文件名**：默认分支以 `GET /repos/{o}/{r}` 的 `default_branch` 为准；文件名除 `README.md` 外，也可能是 `README.zh-CN.md`、`readme.md`。

## 7. `topic:` 类检索的已知污染（2026-10-16 记）

`topic:dsh-plugin` 实测有 **19,309** 个仓库，但**标签被蹭**：`Molunerfinn/PicGo`（图床上传）、`reactive-resume/reactive-resume`（简历）、`Tencent/WeKnora`（RAG 平台）等与 DSH 无关的仓库也打了该标签。

- **结论：热门 `topic:` 不能只按 star 排序取头部**，必须逐条看描述与 topics 是否真相关。
- 判断某组织是否真有相关项目时，用 `org:{name} topic:{topic}` 取真实交集（实测腾讯 org 296 个仓库里只有 2 个带 `dsh-plugin`）。
