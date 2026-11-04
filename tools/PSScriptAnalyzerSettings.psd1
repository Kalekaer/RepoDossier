@{
    # 本工作区的 PSScriptAnalyzer 规则集（2026-10-16）
    # 原则：只排除"我们有意为之"的规则，其余全部保留 —— 让大改期间的告警清单保持干净信号。
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # 我们的脚本就是靠中文 Write-Host 输出给人看的（这是产品的一部分，不是库代码）
        'PSAvoidUsingWriteHost',
        # Join-Path / Split-Path / Select-String 的位置参数是 PowerShell 常态写法，改它只会增加噪声
        'PSAvoidUsingPositionalParameters',
        # 本工作区这些是**本地辅助函数**（不是模块 cmdlet），改名的收益为零、还要动调用点
        'PSUseSingularNouns',
        'PSUseApprovedVerbs'
    )

    Rules = @{
        PSUseBOMForUnicodeEncodedFile = @{
            # 含中文的 .ps1 必须带 UTF-8 BOM：否则 `powershell -File` 会按 GBK 读 → 乱码
            # （2026-10-14 实际踩过：'cal'/'IT' 不是内部或外部命令）
            Enable = $true
        }
        PSAvoidUsingEmptyCatchBlock = @{
            # 保留：空 catch 会吞掉真错误。确实要吞的，写 `$null = $_` 或注释表明意图
            Enable = $true
        }
    }
}