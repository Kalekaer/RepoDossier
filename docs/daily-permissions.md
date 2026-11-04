# 日报权限与减少手动审批

核查日期：2026-11-03。适用本仓库的 Codex 日报；DSH 工作区独立。

## 已选方案

采用宿主 **Approve for me（自动审批）+ 工作区沙箱 + 固定日报联网入口**。常规日报已授权的采集、补证、评分、入库、标签和本地构建不重复询问。质量标准、每日请求预算、断点、评分和发布门禁保持不变。

仓库不能代替用户选择宿主权限模式。当前环境声明工作区可写、网络受限；本机 Codex CLI `0.166.0-alpha.5.1` 的帮助列出 `--approve-for-me`。本次检查用户配置未发现顶层显式审批设置，但这不证明应用当前选择了哪种模式，也不覆盖托管权限。

用户一次性操作：在**运行日报的聊天**输入框下方权限菜单，选择 **Approve for me / 自动审批**。如果该项缺失或禁用，按官方排障检查应用版本和托管要求；不能承诺 Plus 套餐一定显示这个选项。不要仅开启设置中的可用性开关后忘记在聊天里选中。项目没有修改全局配置或宿主安全策略。

自动审批仍可能拒绝或请求用户操作。`approval_policy=never` 只取消询问，不赋予联网权限；Full access 或所有 PowerShell 命令的通配许可不是本方案。模型周额度和执行权限相互独立；本方案不调用付费模型 API、不安装额外模型、不消耗 GitHub 搜索额度做例行权限探测。

## 哪些操作需要什么权限

| 操作 | 所需范围 | 如何避免重复手动操作 |
|---|---|---|
| 检索、metadata、README、许可证、正式 release、issue 评论 | `api.github.com:443` 的公开 GET；如配置代理，还需该代理连接 | 自动审批评估固定入口，队列复用成功响应；不逐条问用户 |
| raw、证据、审阅、备份、日报、页面 | 本仓库普通文件的读写 | 已在工作区范围，照既定流程执行 |
| 启动 PowerShell/curl 子进程 | 现有本地工具 | 固定脚本入口；不执行项目 README 中的命令 |
| GitHub 登录或失效凭据续期 | 用户账户授权 | 有效凭据复用；没有凭据不主动启动登录，匿名限流按原规则处理 |
| 可选 deps.dev / Scorecard 补充证据 | `api.deps.dev` / `api.securityscorecards.dev` | 只有实际需要才申请；不为常规入口预开全部域名 |
| 浏览器、安装依赖、Git 提交/推送、保护目录或工作区外写入 | 超出常规日报的权限 | 日报不执行这些操作；交付本地链接即可 |
| 第三轮新增独立报告、超额或规则例外 | 业务授权 | 沿用原规则；不把它们当成每日必经确认 |

## 固定调用

从工作区使用下列入口，PowerShell 7 路径按实际机器调整。入口没有任意脚本、任意 URL 或工作区根路径参数；它调用既有脚本，不重写采集或评分逻辑。

```powershell
# 默认只显示计划，零联网、零写入
pwsh -NoProfile -NonInteractive -File ./tools/daily-network.ps1

# 日报阶段入口；Date 默认北京时间当天，恢复历史任务时显式指定原日期
pwsh -NoProfile -NonInteractive -File ./tools/daily-network.ps1 -Action Collect -Date 2026-11-03
pwsh -NoProfile -NonInteractive -File ./tools/daily-network.ps1 -Action Maintain -Date 2026-11-03
pwsh -NoProfile -NonInteractive -File ./tools/daily-network.ps1 -Action Readmes -Batch data/audit/reviews/<包目录>
pwsh -NoProfile -NonInteractive -File ./tools/daily-network.ps1 -Action Evidence
```

`Collect` 复用现有轮次；仅显式追加轮次时传 `-Round`。`Maintain` 对历史日期的联网限制仍由原脚本执行。每个动作都有已有的请求/等待预算，不循环跑到清空积压。0 表示该脚本阶段成功；1 表示错误；2 表示未完成、断点保留。任何单阶段成功都不等于日报发布成功。

宿主支持保存命令审批时，可审查**确切的 PowerShell 可执行文件 + `-NoProfile -NonInteractive -File` + 本工作区入口绝对路径**，日期位于之后。不要保存 `pwsh`、任意 `-Command`、任意 `-File` 的宽泛许可。命令前缀匹配受宿主实现约束；固定入口本身不会创建许可。入口及依赖脚本修改后，旧许可也不是代码签名或内容哈希保证，需重新评估其行为。

## 代理与故障

采集、刷新和补证统一采用显式 `-Proxy` → `DSH_HTTP_PROXY` → `HTTPS_PROXY` → `HTTP_PROXY` → `ALL_PROXY`；未配置则直连，不假设其他机器也有 2080 端口。`-NoProxy` 显式禁用继承代理，只影响 HTTP 客户端，不能解除宿主网络限制。代理凭据不打印。代理设置错误与 GitHub 服务故障分开排查。

沙箱拒绝按宿主审批流程处理一次；拒绝后不得更换工具绕过。401/普通403属于认证或访问问题；429/明确限流走原有冷却；证据不足保留未完成。应用模型额度耗尽也不等于 GitHub 限流，恢复时继续已有任务而非新建整轮。

具备管理员管理条件时，可进一步采用命名权限配置与域名白名单。不能只写域名表就声称限制生效：官方要求启用网络代理过滤；新权限配置与旧 `sandbox_mode` 设置不能混用。本机已有代理链和托管策略，本次不替换它们，也不把未验证的白名单模板当成已部署设置。

## 验证边界

回归验证覆盖代理选择、显式直连、非交互缺参、固定入口、错误/未完成退出码传递；另运行 `tools/check-all.ps1`。这些验证不等于已在用户的权限菜单中切换模式，也不等于跑完一轮无人工日报。切换后下一次真实日报应记录是否出现审批、拒绝原因及实际完成状态。

本次实际结果：`check-all` **12/12 通过**，回归测试 **214/214 通过**（新增入口5项、代理7项）；术语表锁定校验通过，7个相关工具的发布副本与真源哈希一致。日志：`data/_tmp/daily-permissions-check-all.log`。没有运行真实联网日报或更改宿主权限；工程验收中现有审阅积压/到期提醒仍如实保留。

官方依据：[权限模式](https://learn.chatgpt.com/docs/permission-modes)、[自动审批](https://learn.chatgpt.com/docs/sandboxing/auto-review)、[命名权限与网络过滤](https://learn.chatgpt.com/docs/permissions)。
