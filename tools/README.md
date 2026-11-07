# tools/ — 流水线脚本一览

开源案卷 · RepoDossier v1.3.0：认证、预算结算、共享冷却、README自动续采及宿主文件模式见 [联网与查询执行说明](../docs/network-and-query-reliability.md)。技能口令保持兼容。

质量闭环入口（2026-10-29）：`review-workbench prepare/verify` 准备并校验真实评审证据，
不自动猜分；`workspace-diff -Source <路径>` 输出逐键数据差异与输入SHA，不覆盖任何原始记录。
`release-readiness -Date <日期>` 或 `check-all -Publish -Date <日期>` 才给出发布判定。
普通check-all通过只代表工程验收。固定参数期未完成任务过期会保存在search-expiry审计目录。

日报 Search 统一入口：`& .\tools\collect-daily.ps1 -Date 2026-10-29`。
串行采集、成功 raw 校验去重、跨进程互斥、跨重启冷却、限流有限等待及续采，
沿用现有计划和 Import。`-DryRun` 只列缺口，`-RequireAuth` 要求认证，
`-MaxWaitSeconds` 默认 900，退出 2 表示未完成，原命令重跑可恢复。
认证读取 GITHUB_TOKEN / DSH_GITHUB_TOKEN / GH_TOKEN 或既有 gh 登录；
默认代理沿用 fetch-series 的环境变量及本机 2080，可 `-NoProxy`。
脚本不打分、不写推荐、不以缓存旧数据冒充今天结果。详情见 RUNBOOK。

周报流程（2026-10-29 修复）：`build-samples` 在日报与 picks 存在时自动确保
上一完整周的周报存在；同一期不重复生成，周一漏跑后补出会标记“补出”。
日报页周报入口只出现在周一那份日报上，链接固定到该周一对应的上一期；
非周一重建会清掉残留入口。`weekly-utils.ps1` 统一北京时间日期、周区间、期号与归档。
周报模板随工具保存于 `tools/templates/weekly.html`，不再依赖外部设计样张目录。

`search-scheduler.ps1` 按固定查询参数自动补页，超 1000 拆星数，单星值仍超限则拆创建时间；
广度优先、最多 7 天过期、逐入口及单轮请求预算。`query-partitions.ps1` 保留供旧计划兼容。
计划是初始条件；每个实际请求的 URL/task 写入 Import 元数据，剩余任务留在 search-progress。

`candidate-ledger.ps1 sync/check/set/sample/evaluate` 是检索结果处置和质量评估入口。
discovery-refresh 自动登记所有观察项（含粗筛疑点），已评分需真实记录，排除需证据。
`editorial-batch prepare` 在评分前固定当期审阅范围；`check` 检查该范围逐项处置、
当天主推荐来源、S/A README校验和、名额及准确披露，接入构建/收工/发布验收。
范围外记录永久留存、继续排队，不等于已评分或自动入库。库内score为空按术语表处理。
独立使用 candidate-ledger -Publish 仍可做全池的严格检查，但不再误当作每日精选的定义。
sample 输出隐藏旧档位的分层评审表；evaluate 要求两位不同评审人、证据及有效入样概率。
它只能评估已观测候选，不能冒充 GitHub 总体优质项目召回。

2026-10-28 质量修复：发现池忽略错误响应，存在 meta 登记时只读取成功登记文件，
并校验可用 SHA256；check-all 新增最新日期发现刷新门禁。
`auto-tag.ps1 -ReviewAuto` 预览历史自动标签里的档位/平台等元信息，
加 `-Apply` 才备份并清理，人工与 merged 来源不改。分类器对“支持 AI 执行”
的自动标签项目优先核对主要用途，避免把系统实用工具当作 AI Agent。

2026-10-28：`date-utils.ps1` 为四个写入入口提供统一 UTC 时间转换，
无效日期在写入前拒绝。`fetch-daily` 保留原始 JSON 并登记 SHA256，拒绝覆盖已有计划/响应；
`check-queries` 核对文件存在、JSON、条数以及新记录的哈希（旧记录兼容）。
`run-manifest -Sync` 重新核对当天覆盖，执行 validate-lib 与 verify-handoff，
把失败写入清单并返回非零。缺日报不能静默收工。

| 脚本 | 作用 | 何时跑 |
|---|---|---|
| `sync-projects.ps1` | 从原始来源重建 `projects.jsonl` + `events.jsonl`（幂等，输入没变自动跳过；`-Force` 强制）。**开头自动备份 tools/ 到 `data/_backup/YYYY-MM-DD/`** | 每次改了原始来源之后 |
| `build-overview.ps1` | 生成 `overview.html`（单文件全内嵌，双击即用）。❗**页面骨架 here-string 里只有 HTML**：CSS 在 `templates\overview.css`、JS 在 `templates\overview.js`（P2-3 后半拆分）→ **改样式/交互请改模板文件**，改完重建即生效 | sync 之后 |
| `query.ps1` | 命令行查询项目库（`-Tag/-Status/-Text/-Top`，支持同义词扩展） | 需要快速查库时 |
| （页内） | **项目对比**：直接在 overview.html 勾选两张卡片 → 右下角「查看对比」，**纯前端、不用命令行** | 用户自己想比两个工具时 |
| `compare.ps1` | **项目对比**（第二阶段⑦）：`.\tools\compare.ps1 A B` 出对比表；`-Similar owner/repo` 找同类；`-Save` 才落盘。**不调 API** | 用户说「比较 A 和 B」「找类似 X」 |
| `add-repo.ps1` | **用户推荐项目入库**（第二阶段⑥）：Agent 先用宿主 HTTP 工具核实，再把字段传进来；已存在则只记用户备注。**脚本本身不联网**；`-Risk 低/中/高` 写台账风险，`-DryRun` 只打印将写入的行（含 round/date）不落盘 | 用户说「这个项目不错：owner/repo」 |
| `compose.ps1` | **工具组合建议**（v3.1 第八节）：按需求从库里挑工具并**按用途分组**（每组最优 1–2 个）。只归类、不编造流程。**不调 API** | 用户说「我要做 ___」 |
| `auto-tag.ps1` | 给缺标签的项目**自动补功能标签/搜索词**（topics + 中文描述片段；不覆盖人工条目）。批量入库后跑 | 用户一次加了多个项目后 |
| `suggest-terms.ps1` | 挖「还没进词表」的新词作为同义词候选（频率 + 示例仓库），**让词表随库增长** | 库每涨 30–50 条 |
| `gaps.ps1` | **搜索缺口闭环**：`-Add "词"` 记下搜不到的词；默认复检并给补词建议 | 用户说「搜不到」之后 |
| `add-plan.ps1` | 把 /tool-stack 配好的一套**固化成网页方案**（查重后写 data/plans.json） | 用户说「写进网页里」 |
| `daily-questions.ps1` | 收尾只输出**真需要拍板**的问题（风险高的项目、发版/删数据/花钱）；其余自动做完不问，输出为空就别问（2026-10-20 改） | **每日流程收尾** |
| `suggest-plans.ps1` | 挖「工具攒够但没有对应场景」的方向 → data/plan-suggestions.jsonl 待批 | 库明显变大后 |
| `check-config.ps1` | 校验 `config.json` 与标准不冲突 + status 读写实测（`-StatusRoundTrip -Restore`） | 改配置后 / 验收 |
| `check-page.ps1` | **真跑页面 JS**（`+ check-page.js`）：语法 → 初始化 → **逐个项目验证卡片能点开** → 筛选 → **hash 路由 ⑪–⑭**（进入/后退/刷新一致、facet 复原、legend 冷启动不白屏、深链开面板）→ 数组 null 扫描。单文件页 JS 出错时页面照常渲染，只有真跑才发现 ｜ **加 `-Real` 再跑真机层**（真 Edge + CDP **两个探针：路由 14 + 页面功能 21～22 = 36 项**；沙箱内 Chromium 起不来 → 打印 SKIP、退出码 2，**不代表页面坏**） | **每次 build-overview 之后，PASS 才算出货** |
| `history-probe-cdp.js` | **真机探针**（真 Edge + CDP，14 项）：真鼠标事件点导航、**真浏览器历史前进/后退**、页面内 `history.back/forward`、筛选进 URL、连续后退不崩 → 结果落 `data\_tmp\hist.json`（退出码 0=全过 / 2=有失败）。**沙箱内起不了浏览器**（需一次性放开权限，或在普通桌面会话跑）。**已被 `check-page.ps1 -Real` 包装** ✓（E-3，2026-10-17） | 改了路由/导航之后，想确认真机行为 |
| `history-probe.js` | 同上，**Electron 窗口版**（备选；`webContents.navigationHistory` 真机后退）。❗**不要**设 `ELECTRON_RUN_AS_NODE`（那会退化成 Node，就不是真浏览器了） | 上面那条跑不动时 |
| `page-smoke-cdp.js` | **页面功能真机巡检**（真 Edge + CDP，21～22 项）：首屏/KPI、搜索与空态、分类、徽章、排序、详情深链 + 一句话理解 + **适合谁**、方案/工作区深链、图例抽屉、`/` 快捷键、对比条、首页图表、外部请求 0、无横向溢出、无控制台错误 → 结果落 `data\_tmp\page-smoke.json`（退出码 0/1/2）。❗**断言是数据驱动的**（从推荐区里找**真带 `aud`** 的条目），绝不写死项目 ✗（写死 `pre-commit` 曾造成假红，2026-10-17 修） | 改了页面交互后（一般不用手敲：`check-page.ps1 -Real` 会跑） |
| `dupes-probe.ps1` | **P2-4 相似度去重侦察**（离线、零安装、**只产候选、绝不改现有数据**）：全部项目两两算相似度（人话层中文 0.40 + 功能标签 0.25 + 仓库名 0.20 + 同二级分类 0.15；**同名不同 owner** 直接抬到 ≥90）→ 候选对 + 连通簇 + 确认/否决台账：`data\dupes-candidates.jsonl`、`data\dupes-clusters.json`、`data\dupes-confirmed.jsonl`、`data\dupes-rejected.jsonl`（退出码 0/1，带 `-SelfTest` 4 项） | 想复查"库里有没有重复 / 换皮马甲"时；**相似 ≠ 重复，确认前不要合并** ✗ |
| `classify-semantic.ps1` | **P2-5 语义分类复核入口**（包装 `classify-semantic.py`）：venv / 模型 / 缓存全在工作区内 → `& ".\tools\classify-semantic.ps1"`（`-SelfTest` 秒级逻辑自检 ｜ `-Fixture` 手工小样本质量门 ｜ `-Json`）｜ 退出码 0 ｜ 1 ｜ **2 = 环境未就绪** | 想用语义向量复核分类时（**质量门不过就别信它的建议** ✗） |
| `classify-semantic.py` | 分析本体（fastembed `BAAI/bge-small-zh-v1.5`）：类目文档 = 一级说明 + 二级名 + 关键词（`--kw 0` = 全部）｜ **绝对下限 sim + 相对差** 双条件 ｜ **无锚点类目判 `no-anchor`**（不冒充 suggest）｜ `--list-models` / `--fixture` / `--selftest` | 同上 |
| `setup-fastembed.ps1` | **一次性**把语义环境装进工作区内（venv → `data\_pyenv`、模型 → `data\_models`、pip 缓存 → `data\_pip-cache`，**不碰系统 Python** ✓）：`-IndexUrl` 默认清华镜像、`-HfEndpoint` 默认 hf-mirror、pip 超时 30s | 换机器 / 重装时（**要放开权限**：沙箱内 python 子进程与 ACL 都不行 ✗） |
| `rebuild-page.ps1` | **写入即重建的统一入口**（P1-16）：sync 投影 → build 页面 → **自检页面真的变新**。写入器写盘后自动调用；`$env:DSH_SKIP_REBUILD=1` 跳过、`-Quiet` 只静默进度（**错误永远打印**）、`-Force` 强制重算投影 | 一般不用手跑；想手动同步就双击根目录 **`刷新页面.cmd`** |
| `smoke-test.ps1` | **功能巡检（工具链层）**：把每个工具用安全模式真跑一遍并断言输出标志（**30 项**）→ `& ".\tools\smoke-test.ps1"` ✓ | 任何时候（改动工具后建议跑）
| `validate-lib.ps1` | **数据契约校验**（零依赖，读 `data/schema.json`）：必填字段 / 枚举 / 唯一键 / `date`=文件名 / 分类；2026-10-19 起含 `data/picks/<date>.jsonl` 与 `data/snapshots/<date>.jsonl` | 改数据或 `schema.json` 之后
| `add-rows.ps1` | **picks / CSV 的唯一写入口**（2026-10-19）：写入前校验字段 + 判重；已存在默认拒绝，`-Update` 刷新旧行，`-DryRun` 只看计划 | 写 `data/picks/<date>.jsonl` / `recommend-log.csv` 时（**不要再手写**）
| `append-snapshot.ps1` | **写当天快照的唯一入口**：自动按 `date+repo` 取已用最大 `round` +1、日期强制 ISO 8601、写前查唯一键；`-Apply` 才落盘，`-Json` 给脚本读 | 每天写完检索结果后 |
| `migrate-snapshots-round.ps1` | 给 `data/snapshots/*.jsonl` 补 `round`（同日多轮编号 1..n，幂等）；默认 dry-run，`-Apply` 才写盘 | 一次性迁移 / 以后补历史快照
| `append-guard.ps1` | **append 写前唯一键**（只读，2026-10-19）：picks 按 `date+full_name`、CSV 按 `仓库` 判重；退出码 0=可追加 / 1=已存在（**刷新旧行，不要再追加**）/ 2=参数错误 | 写 `data/picks/<date>.jsonl` 或 `recommend-log.csv` 之前
| `verify-handoff.ps1` | **交接验收**：把 `新会话交接-*.md` 里的数字/路径/编号/口径与实物逐条对账 → `& ".\tools\verify-handoff.ps1"` ✓ | 改完交接后必跑
| `calibrate.ps1` | 黄金集校准（2026-10-21）：guess/human 与 agent 的 0–5 一致性、MAE、κ、混淆矩阵 → `data/_tmp/calibration.md` | 改 rubric 前后 |
| `taxonomy-guard.ps1` | 分类建议四道闸（2026-10-21）：样本/定义/命名/重叠 + 废弃项检查；`-Strict` 可作门禁 | 落分类前 / 周报巡检 |
| `fetch-evidence.ps1` | 抓评分证据（2026-10-21）：deps.dev 项目事实/包映射/SLSA/findings + 可选 Scorecard 18 项 → `data/enrich/evidence.jsonl`；只读、失败回退、按天缓存 | 打分前 / 周报巡检 |
| `weekly-check.ps1` | **周报巡检**（2026-10-20，只读）：列出人话层缺口、同义词待批、缺口词、分类/方案建议、用户自推缺档位、高风险主推荐、缺日、发布态；周报时由 AI 按清单自动处理，只有删数据/超额花费/红线例外才问 | 每周出周报前 |
| `build-weekly.ps1` | **周报页生成器**（2026-10-20）：按 `周报设计-2026-10-20.md` §3 口径算 found / scored / 主推荐 / 新入库 / 星数周增 / 状态变更，换掉样张里的数据与周标签 → `data/site/weekly-<周日>.generated.html`；`-Check` 只算不写（W01 与样张逐项对得上） | 每周一日报落盘后 |
| `build-monday.ps1` | **周一入口**（2026-10-20）：确保上周周报存在 → 构建周一日报 → 顶部中央注入 `WEEKLY / Wxx` 入口；`-DryRun` 只打印计划、`-Page` 在副本上演练注入 | 每周一 |
| `gen-query-docs.ps1` | 从 `data/queries.json` 生成三份检索式文档（SOURCES / skill reference / PROMPT 顺序行）；`-Check` 只比对 | 改检索式之后 |
| `fetch-daily.ps1` | 当天检索计划（`-PlanOnly` → `data/raw/<date>/r<N>/plan.json`）+ 把 `web_fetch` 结果登记成 raw（`-Import Q2b -File x.json`）；**不联网** | 每天开工 / 补跑 |
| `check-queries.ps1` | 检索式一致性（`-Static`：文档/星期表/调用区间）+ 当天覆盖（`-Date`：必跑有没有登记、条件查询是否评估） | 改检索式后 / 收工前 |
| `responsive-probe-cdp.js` | **620 / 打印 / reduced-motion 三档真机验收**（2026-10-20，六页 × 三档 = 42 项）：620 宽无横向溢出、打印隐藏交互控件/无溢出、reduced-motion 无运行中动画 → 结果落 `data\_tmp\responsive-probe.json`（退出码 0/1/2；需一次性放开浏览器权限） | 改版式/动效/打印样式后 |

## 调用约定

页面兼容入口：`start-site.ps1 [-NoOpen] [-Port 8788]` 启动或复用 `serve-site.py` 的本机只读服务，`-Stop` 只关闭本入口记录且身份匹配的进程。根目录 `打开工具库.cmd` 供双击使用。只提供页面/静态资源，不列目录、不开放 raw 或配置文件；不修改日报数据。它解决本地文件预览的访问方式问题，不代表 Codex 的 HTML 内嵌预览限制已被解除。

日报联网稳定入口：`daily-network.ps1` 默认只显示计划；`-Action Collect/Maintain/Readmes/Evidence` 分别调用现有采集、维护、README补证、证据队列。使用 `pwsh -NoProfile -NonInteractive -File <入口绝对路径>`，日期作为后续参数，避免把日期嵌在授权命令字符串里。原入口仍兼容；不会自动更改宿主权限。说明见 `docs/daily-permissions.md`。

上述联网脚本的代理统一使用显式参数、`DSH_HTTP_PROXY`、`HTTPS_PROXY`、`HTTP_PROXY`、`ALL_PROXY`；未配置则直连，`-NoProxy` 明确关闭继承代理。代理选择不能绕过宿主网络限制。

2026-11-02流程补齐：`daily-maintenance.ps1` 在当天执行有预算的时间序列刷新及证据队列；`-PlanOnly` 不联网。`evidence-queue.ps1 enqueue/run/sync-events/check` 统一管理 metadata、README、许可证、最新正式release、issue评论任务。缓存使用不可变SHA256内容文件、版本线索、有效期和ETag条件请求。变化原因保留，重复取数按项目和资源合并。`review-workbench prepare -Changes` 生成证据齐备的变化复核包，不自动评分。`review-metrics.ps1 -From <实测JSONL>` 保存真实审阅耗时及明确裁定，渠道报告区分已有S/A评分与当天自动入库S/A；缺测值保持空。完整数据约定与验证见 `docs/evidence-pipeline-closure-2026-11-02.md`。

审阅稳定性：`review-health.ps1 -Date YYYY-MM-DD` 显示到期与容量差距；`review-workbench.ps1 prepare -Date YYYY-MM-DD -Backlog` 准备跨日审阅，优先到期延期，相同范围复用已校验证据包。后续仍须真实审阅，不自动评分。细节见 `docs/review-stability-2026-10-29.md`。

独立双评：`review-workbench.ps1 prepare -SampleFile <固定样本.jsonl>` 准备相同事实；`fetch-review-readmes.ps1 -Batch <目录>` 读取公开README（不执行项目）；`review-compare.ps1 -Frame <样本> -ReviewA <一审> -ReviewB <二审>` 对比完整独立输出，允许排除/缺证而不伪填档位；`export-review-bundle.ps1 -Batch <目录> -Frame <样本> -Reviews <审阅文件数组>` 导出带指纹的公开证据和规则包。不同设备按相对路径读取，不依赖原机器绝对路径。见 `docs/q3s-and-second-review-2026-10-29.md`。

- 全部在工作区根目录用 `& ".\tools\<脚本名>"` 调用（沙箱下 `pwsh -File` 不可用）。
- `sync-projects.ps1` / `build-overview.ps1` 是**投影生成器**，可随时全量重建；
  `add-repo.ps1` 写的是**原始来源**（seen/meta/snapshots/user-notes），写错要手工修对应行。
- 脚本本体**不可再生**——sync 每次运行会自动备份到 `data\_backup/`，误改后从那里复制回来。
