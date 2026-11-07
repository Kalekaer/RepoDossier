# 开源案卷 · 5分钟上手

## 第 1 步：浏览演示工具库

解压发布包。Windows 上安装好 PowerShell 7 和 Python 3.9+ 后，双击 `打开工具库.cmd`；它只启动本机静态页面服务。也可直接打开 `index.html`，若宿主拦截内嵌预览则使用前述本机入口。

首页看概览；每日精选看示例日报；全库按用途搜索与筛选；计划与工作区查看工具组合。演示数据共15个项目，个人记录为空。页面只读，修改通过助手和既有脚本完成。

## 生成自己的日报

在 DSH 或 Codex 中打开解压目录，让助手先读 `AGENTS.md` 与 `PROMPT-daily.md`。

1. 配置一次 GitHub 登录：可用已有 gh 登录、已有 Git 凭据，或当前进程的 `GITHUB_TOKEN` / `DSH_GITHUB_TOKEN` / `GH_TOKEN`。不要把真实 token 写进仓库、聊天或镜像地址。
2. `pwsh -NoProfile -File tools/daily-network.ps1 -Action Status` 检查凭据是否可读和当前冷却。状态检查不发HTTP；权限与凭据不可用时请先解决，不用匿名模式反复试。
3. 让助手执行“跑今天的日报”。采集、补证、审阅、写入、重建和真实发布验收是不同阶段。

代理使用显式参数或 `DSH_HTTP_PROXY`、`HTTPS_PROXY`、`HTTP_PROXY`、`ALL_PROXY`，不假设本机有固定代理端口。网络许可由宿主管理，脚本不能取消必要授权。Windows 为本次实际验证平台，其余设备仍需验证环境与通道。

## 断点与大响应

重复原日期、原轮次续采，不新建整轮。源站限流按真实时间等待，README标准入口最多累计等待30分钟。真实预算耗尽、认证或网络不可用时保留断点。

DSH 的本机curl不可用而宿主HTTP可用时，使用 `collect-daily -NextRequest` 的文件模式；完整响应落盘，模型只看下一步和进度。详见 [联网与查询执行说明](docs/network-and-query-reliability.md)。不能少跑Q或缩小每页取数来声称完成。

## 验证

`pwsh -NoProfile -File tools/check-all.ps1` 检查发布包工程完整性；真实日报用 `-Publish -Date YYYY-MM-DD` 另验。示例包没有真实当期审阅范围，直接进行真实发布验收应被拒绝。
