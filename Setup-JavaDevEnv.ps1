#Requires -Version 5.1
<#
=============================================================================
  Setup-JavaDevEnv.ps1  —  Windows Java 开发环境一键配置
  ---------------------------------------------------------------------------
  支持组件：JDK / Maven / Git / Node.js / dsh / IntelliJ IDEA /
            PostgreSQL / Redis / DBeaver / HeidiSQL / 自定义 extras
  特点：绿色免安装、自动探测已有环境、用户级环境变量（无需管理员）、
        桌面快捷方式、配置可定制
  用法：见 install.cmd 或 -Action help
=============================================================================
#>
[CmdletBinding()]
param(
    [ValidateSet('install', 'status', 'doctor', 'uninstall', 'plan', 'restore', 'autostart', 'help')]
    [string]$Action = 'install',

    [string[]]$Components = @(),
    [string]$Profile = '',
    [string]$ConfigFile = '',
    [string]$Root = '',
    [string]$BackupFile = '',

    [switch]$Force,
    [switch]$DryRun,
    [switch]$Interactive,
    [switch]$NoShortcuts,
    [switch]$NoEnv,
    [switch]$Offline,
    [switch]$SkipDownload,
    [switch]$Autostart,
    [Alias('y')]
    [switch]$Yes,

    [ValidateSet('Debug', 'Info', 'Warn', 'Error', 'None')]
    [string]$LogLevel = 'Info'
)

$ErrorActionPreference = 'Stop'
$script:ExitCode = 0

# powershell -File 传参时 "jdk,maven" 会作为一个字符串整体传入，这里统一拆分成组件 key
$componentList = New-Object Collections.ArrayList
foreach ($item in @($Components)) {
    foreach ($part in ([string]$item -split ',')) {
        $p = $part.Trim()
        if (-not [string]::IsNullOrWhiteSpace($p)) { [void]$componentList.Add($p) }
    }
}
$Components = $componentList.ToArray()

# ---------------------------------------------------------------------------
# 加载库
# ---------------------------------------------------------------------------
$script:ScriptBase = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:ScriptBase)) { $script:ScriptBase = (Get-Location).Path }

foreach ($lib in @('00-Common.ps1', '10-Catalog.ps1', '20-Configure.ps1', '30-Actions.ps1')) {
    $libPath = Join-Path $script:ScriptBase (Join-Path 'lib' $lib)
    if (-not (Test-Path -LiteralPath $libPath)) { throw "缺少脚本库文件: $libPath" }
    . $libPath
}

Initialize-BaseEnvironment

function Show-Help {
    Write-Host ''
    Write-Host '  Java 开发环境一键配置工具 (JavaDevEnv)' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  常用用法:' -ForegroundColor White
    Write-Host '    install.cmd                      一键安装（按配置文件的推荐组合，全自动）'
    Write-Host '    install.cmd -Interactive         交互式选择要安装的组件'
    Write-Host '    install.cmd -Components jdk,maven,git'
    Write-Host '    install.cmd -Profile minimal     可选 minimal / standard / full'
    Write-Host '    install.cmd -Root E:\JavaDevEnv  指定安装目录'
    Write-Host '    install.cmd -DryRun              只显示计划，不做任何改动'
    Write-Host '    install.cmd -Force               强制重新下载安装'
    Write-Host '    install.cmd -Action autostart    应用配置里的开机自启设置（改完 user.json 后用）'
    Write-Host '    status.cmd                       查看当前环境状态'
    Write-Host '    doctor.cmd                       环境自检（版本、连通性、端口、自启）'
    Write-Host '    uninstall.cmd                    卸载（可保留 data 数据目录）'
    Write-Host ''
    Write-Host '  全部参数:' -ForegroundColor White
    Write-Host '    -Action    install|status|doctor|uninstall|plan|restore|autostart|help'
    Write-Host '    -Components <逗号分隔>   jdk,maven,ide,git,node,dsh,dsh-cli,postgres,redis,dbeaver,heidisql,windterm,apifox,tinyrdm'
    Write-Host '    -Profile <名称>          minimal|standard|full'
    Write-Host '    -ConfigFile <文件>       指定配置文件（默认 config\default.json + config\user.json）'
    Write-Host '    -Root <目录>             安装根目录'
    Write-Host '    -BackupFile <文件>       配合 -Action restore 恢复环境变量'
    Write-Host '    -Force -DryRun -Interactive -NoShortcuts -NoEnv -Offline -SkipDownload -Autostart'
    Write-Host '    -LogLevel Debug|Info|Warn|Error|None'
    Write-Host ''
    Write-Host '  定制化: 复制 config\user.example.json 为 config\user.json 后按需修改。' -ForegroundColor DarkGray
    Write-Host ''
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
try {
    if ($Action -eq 'help') { Show-Help; exit 0 }

    # ---------------- 配置 ----------------
    # 注意：PowerShell 变量名不区分大小写，$ConfigFile（脚本参数）与 $configFile 是同一个变量！
    # 因此这里必须用完全不同的名字（$mainConfigPath），否则解析默认路径后会“看起来像”用户传了 -ConfigFile，
    # 导致 config\user.json 被静默跳过。
    $mainConfigPath = $ConfigFile
    $userSpecifiedConfig = -not [string]::IsNullOrWhiteSpace($ConfigFile)
    if ([string]::IsNullOrWhiteSpace($mainConfigPath)) { $mainConfigPath = Join-Path $script:ScriptBase 'config\default.json' }
    if (-not (Test-Path -LiteralPath $mainConfigPath)) { throw "找不到配置文件: $mainConfigPath" }
    $mainConfigPath = (Resolve-Path -LiteralPath $mainConfigPath).Path

    $cfg = Read-JsonFile -Path $mainConfigPath
    $userConfigFile = Join-Path $script:ScriptBase 'config\user.json'
    if ($userSpecifiedConfig) { $userConfigFile = '' }
    if (-not [string]::IsNullOrWhiteSpace($userConfigFile) -and (Test-Path -LiteralPath $userConfigFile)) {
        Write-Log -Message "加载用户定制配置: $userConfigFile" -Level 'Debug'
        $cfg = Merge-DeepHashtable -Base $cfg -Override (Read-JsonFile -Path $userConfigFile)
    }
    $script:Config = $cfg

    if (-not [string]::IsNullOrWhiteSpace($Root)) { $cfg['installRoot'] = $Root }
    if (-not [string]::IsNullOrWhiteSpace($Profile)) { $cfg['profile'] = $Profile }
    if ($Autostart) {
        foreach ($name in @('postgres', 'redis', 'dsh')) {
            if ($cfg.components.ContainsKey($name) -and ($cfg.components[$name] -is [hashtable])) {
                $cfg.components[$name]['autostart'] = $true
            }
        }
    }

    # ---------------- 目录 ----------------
    $installRoot = Resolve-InstallRoot -Config $cfg
    $cfg['installRoot'] = $installRoot
    $script:Ctx = @{
        Root           = $installRoot
        Data           = Join-Path $installRoot 'data'
        Cache          = Join-Path $installRoot 'cache'
        Logs           = Join-Path $installRoot 'logs'
        Bin            = Join-Path $installRoot 'bin'
        Config         = Join-Path $installRoot 'config'
        ScriptRoot     = $script:ScriptBase
        ConfigFile     = $mainConfigPath
        UserConfigFile = $userConfigFile
    }

    $script:Options = @{
        Force        = [bool]$Force
        DryRun       = [bool]($DryRun -or ($Action -eq 'plan'))
        Interactive  = [bool]$Interactive
        NoShortcuts  = [bool]$NoShortcuts
        NoEnv        = [bool]$NoEnv
        Offline      = [bool]$Offline
        SkipDownload = [bool]$SkipDownload
        Components   = @($Components)
    }

    # 只有安装动作才创建目录结构；status / doctor / plan 保持零副作用
    if ($Action -eq 'install') {
        foreach ($dir in @($script:Ctx.Data, $script:Ctx.Cache, $script:Ctx.Logs, $script:Ctx.Bin, $script:Ctx.Config)) {
            New-DirectoryFor -Path $dir -Quiet | Out-Null
        }
    }
    # 日志级别：命令行未显式指定时使用配置文件中的设置
    $effectiveLogLevel = $LogLevel
    if (-not $PSBoundParameters.ContainsKey('LogLevel')) {
        $cfgLevel = [string](Get-ConfigValue -Path 'logging.level' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($cfgLevel)) { $effectiveLogLevel = $cfgLevel }
    }
    Initialize-Logging -Directory $script:Ctx.Logs -Level $effectiveLogLevel

    # 解析配置中的 {installRoot} 等占位符
    $tokens = @{
        installRoot = $script:Ctx.Root
        dataRoot    = $script:Ctx.Data
        cacheRoot   = $script:Ctx.Cache
        logsRoot    = $script:Ctx.Logs
        binRoot     = $script:Ctx.Bin
        userProfile = $env:USERPROFILE
    }
    $cfg = Resolve-ConfigTokens -Node $cfg -Tokens $tokens
    $script:Config = $cfg

    # ---------------- 横幅 ----------------
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
    Write-Host ("  Java 开发环境一键配置    JavaDevEnv v$($script:ToolVersion)") -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
    Write-Host ("  动作: $Action    安装目录: $installRoot") -ForegroundColor Gray
    Write-Host ("  系统: $((Get-Culture).Name) / $(if (Test-IsAdmin) { '管理员' } else { '普通用户' })    日志: $($script:LogFile)") -ForegroundColor DarkGray

    if ($script:Options.DryRun -and $Action -ne 'plan') { Write-Host '  [试运行模式] 不会修改系统' -ForegroundColor Yellow }

    # ---------------- 版本解析 ----------------
    $resolved = @{}
    if ($Action -ne 'restore' -and $Action -ne 'uninstall') {
        Write-Log -Message '解析组件版本信息...' -Level 'Step'
        $resolved = Resolve-DynamicVersions -Config $cfg
    }

    switch ($Action) {
        'install' { Invoke-InstallAction -Config $cfg -Resolved $resolved }
        'plan' { Invoke-InstallAction -Config $cfg -Resolved $resolved }
        'status' { Invoke-StatusAction -Config $cfg -Resolved $resolved }
        'doctor' { Invoke-DoctorAction -Config $cfg -Resolved $resolved }
        'uninstall' { Invoke-UninstallAction -Config $cfg -Resolved $resolved -BackupFile $BackupFile }
        'autostart' { Invoke-AutostartAction -Config $cfg -Resolved $resolved }
        'restore' {
            if ([string]::IsNullOrWhiteSpace($BackupFile)) { throw '请用 -BackupFile 指定要恢复的环境变量备份文件' }
            [void](Restore-UserEnvironment -File $BackupFile)
        }
    }

    $failed = @($script:Results | Where-Object { $_.Status -eq 'failed' })
    if ($failed.Count -gt 0) { $script:ExitCode = 1 }
} catch {
    Write-Err "执行失败: $($_.Exception.Message)"
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Log -Message $_.InvocationInfo.PositionMessage -Level 'Error'
    }
    if ($_.ScriptStackTrace) { Write-Log -Message $_.ScriptStackTrace -Level 'Error' }
    $script:ExitCode = 2
} finally {
    if ($script:LogFile) { Write-Log -Message "结束，退出码 $($script:ExitCode)" -Level 'Info' -NoConsole }
}

exit $script:ExitCode
