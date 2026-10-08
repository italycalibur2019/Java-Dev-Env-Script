# ===========================================================================
#  20-Configure.ps1  —  各组件的初始化与配置
# ===========================================================================

# ---------------------------------------------------------------------------
# 文件写出助手
# ---------------------------------------------------------------------------
function Write-TextFileNoBom {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Lines)
    if ($script:Options -and $script:Options.DryRun) { Write-Info "[试运行] 生成文件 $Path"; return }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllLines($Path, $Lines, (New-Object Text.UTF8Encoding $false))
}

function Write-TextFileBom {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Lines)
    if ($script:Options -and $script:Options.DryRun) { Write-Info "[试运行] 生成文件 $Path"; return }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllLines($Path, $Lines, (New-Object Text.UTF8Encoding $true))
}

function Add-SpecShortcut {
    param(
        [hashtable]$Spec,
        [string]$Item,
        [string]$Name,
        [string]$Target,
        [string]$Arguments = '',
        [string]$Icon = '',
        [int]$WindowStyle = 1
    )
    $list = New-Object Collections.ArrayList
    foreach ($s in @($Spec.Shortcuts)) { [void]$list.Add($s) }
    [void]$list.Add(@{ Item = $Item; Name = $Name; Target = $Target; Arguments = $Arguments; Icon = $Icon; WindowStyle = $WindowStyle })
    $Spec.Shortcuts = $list.ToArray()
}

# ---------------------------------------------------------------------------
# 图标资源（仓库 assets\icons -> 安装目录 icons\）
# ---------------------------------------------------------------------------
function Get-IconAsset {
    # 把仓库自带的 .ico 复制到安装目录并返回该路径；仓库里没有时返回空串（调用方退回系统图标）。
    # 之所以复制而不是直接引用仓库路径：安装目录要能脱离源码目录独立存在（例如拷到别的机器）。
    param([Parameter(Mandatory = $true)][string]$Name)
    $src = Join-Path $script:Ctx.ScriptRoot (Join-Path 'assets\icons' $Name)
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Debug2 "图标资源缺失: $src（将退回系统图标）"
        return ''
    }
    $iconDir = Join-Path $script:Ctx.Root 'icons'
    $dst = Join-Path $iconDir $Name
    if ($script:Options -and $script:Options.DryRun) { return $dst }
    try {
        if (-not (Test-Path -LiteralPath $iconDir)) { New-Item -ItemType Directory -Path $iconDir -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dst -Force
    } catch {
        Write-Debug2 "复制图标失败: $($_.Exception.Message)"
    }
    return $dst
}

# ---------------------------------------------------------------------------
# Maven
# ---------------------------------------------------------------------------
function New-MavenSettingsXml {
    param([hashtable]$MavenCfg, [string]$Root)
    $settings = Get-ObjectProperty -Object $MavenCfg -Name 'settings'
    if (-not $settings) { return '' }
    $mirrorKey = [string](Get-ObjectProperty -Object $settings -Name 'mirror' -Default 'aliyun')
    $mirrorUrls = Get-ObjectProperty -Object $MavenCfg -Name 'mirrorUrls'
    $mirrorUrl = ''
    if ($mirrorUrls) { $mirrorUrl = [string](Get-ObjectProperty -Object $mirrorUrls -Name $mirrorKey -Default '') }
    $localRepoMode = [string](Get-ObjectProperty -Object $settings -Name 'localRepository' -Default 'user')

    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine('<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"')
    [void]$sb.AppendLine('          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"')
    [void]$sb.AppendLine('          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 http://maven.apache.org/xsd/settings-1.0.0.xsd">')
    [void]$sb.AppendLine('  <!-- 由 JavaDevEnv 生成；如需手工维护请直接编辑本文件 -->')
    if ($localRepoMode -eq 'portable') {
        $repoDir = Join-Path $Root ([string](Get-ObjectProperty -Object $settings -Name 'portableRepoDir' -Default 'm2repo'))
        [void]$sb.AppendLine("  <localRepository>$repoDir</localRepository>")
    }
    if (-not [string]::IsNullOrWhiteSpace($mirrorUrl)) {
        $escaped = $mirrorUrl.Replace('&', '&amp;')
        [void]$sb.AppendLine('  <mirrors>')
        [void]$sb.AppendLine('    <mirror>')
        [void]$sb.AppendLine('      <id>javadevenv-' + $mirrorKey + '</id>')
        [void]$sb.AppendLine('      <name>JavaDevEnv ' + $mirrorKey + ' mirror</name>')
        [void]$sb.AppendLine("      <url>$escaped</url>")
        [void]$sb.AppendLine('      <mirrorOf>central</mirrorOf>')
        [void]$sb.AppendLine('    </mirror>')
        [void]$sb.AppendLine('  </mirrors>')
    }
    [void]$sb.AppendLine('</settings>')
    return $sb.ToString()
}

function Configure-Maven {
    param([Parameter(Mandatory = $true)][hashtable]$Spec)
    $mavenCfg = $Spec.Comp
    $settings = Get-ObjectProperty -Object $mavenCfg -Name 'settings'
    if (-not $settings) { return }
    if (-not [bool](Get-ObjectProperty -Object $settings -Name 'enable' -Default $true)) { return }

    $xml = New-MavenSettingsXml -MavenCfg $mavenCfg -Root $script:Ctx.Root
    if ([string]::IsNullOrWhiteSpace($xml)) { return }

    $refFile = Join-Path $script:Ctx.Config 'maven-settings.xml'
    Write-TextFileNoBom -Path $refFile -Lines @($xml -split '\r?\n')

    $userSettings = Join-Path $env:USERPROFILE '.m2\settings.xml'
    $overwrite = [bool](Get-ObjectProperty -Object $settings -Name 'overwriteExisting' -Default $false)
    $m2Dir = Split-Path -Parent $userSettings
    if (-not (Test-Path -LiteralPath $m2Dir)) { New-Item -ItemType Directory -Path $m2Dir -Force | Out-Null }

    if (-not (Test-Path -LiteralPath $userSettings)) {
        Write-TextFileNoBom -Path $userSettings -Lines @($xml -split '\r?\n')
        Write-Ok "已生成 Maven 配置: $userSettings"
    } elseif ($overwrite) {
        $backup = "$userSettings.bak-" + (Get-Date -Format 'yyyyMMddHHmmss')
        Copy-Item -LiteralPath $userSettings -Destination $backup -Force
        Write-TextFileNoBom -Path $userSettings -Lines @($xml -split '\r?\n')
        Write-Ok "已覆盖 Maven 配置（原文件备份为 $([IO.Path]::GetFileName($backup))）"
    } else {
        Write-Warn "已存在 $userSettings，为安全起见未修改；参考配置见 $refFile"
    }

    # 提供带 -s 参数的 mvn 包装脚本
    $mvnDev = Join-Path $script:Ctx.Bin 'mvn-dev.cmd'
    $mvnExe = Join-Path $Spec.Target 'bin\mvn.cmd'
    Write-TextFileNoBom -Path $mvnDev -Lines @(
        '@echo off',
        'rem JavaDevEnv: run maven with the generated settings.xml',
        "`"$mvnExe`" -s `"$refFile`" %*"
    )
}

# ---------------------------------------------------------------------------
# IntelliJ IDEA
# ---------------------------------------------------------------------------
function Configure-Ide {
    param([Parameter(Mandatory = $true)][hashtable]$Spec)
    $cfg = $Spec.Comp
    $binDir = Join-Path $Spec.Target 'bin'

    if ([bool](Get-ObjectProperty -Object $cfg -Name 'portable' -Default $true)) {
        $propsFile = Join-Path $binDir 'idea.properties'
        Set-ManagedBlock -File $propsFile -Id 'idea-portable' -Lines @(
            'idea.config.path=${idea.home.path}/portable/config',
            'idea.system.path=${idea.home.path}/portable/system',
            'idea.plugins.path=${idea.home.path}/portable/plugins',
            'idea.log.path=${idea.home.path}/portable/log'
        )
        Write-Ok '已启用 IDEA 便携模式（配置/插件/缓存均位于安装目录内 portable 子目录）'
    }

    $heap = [string](Get-ObjectProperty -Object $cfg -Name 'vmOptionsHeap' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($heap)) {
        $vmFile = Join-Path $binDir 'idea64.exe.vmoptions'
        Set-ManagedBlock -File $vmFile -Id 'idea-vmoptions' -Lines @("-Xmx$heap")
        Write-Ok "已设置 IDEA 最大堆内存 $heap"
    }

    $edition = [string](Get-ObjectProperty -Object $cfg -Name 'edition' -Default 'IC')
    $shortcutName = 'IntelliJ IDEA'
    if ($edition -eq 'IU') { $shortcutName = 'IntelliJ IDEA Ultimate' }
    Add-SpecShortcut -Spec $Spec -Item 'ide' -Name $shortcutName -Target $Spec.ProbePath -Icon $Spec.ProbePath
}

# ---------------------------------------------------------------------------
# Node / npm
# ---------------------------------------------------------------------------
function Configure-Node {
    param([Parameter(Mandatory = $true)][hashtable]$Spec)
    $registry = [string](Get-ObjectProperty -Object $Spec.Comp -Name 'npmRegistry' -Default '')
    if ([string]::IsNullOrWhiteSpace($registry)) { return }

    $refFile = Join-Path $script:Ctx.Config 'npmrc'
    Write-TextFileNoBom -Path $refFile -Lines @("# JavaDevEnv 生成的 npm 配置参考", "registry=$registry")

    if (-not [bool](Get-ObjectProperty -Object $Spec.Comp -Name 'writeUserNpmrc' -Default $true)) { return }
    $userNpmrc = Join-Path $env:USERPROFILE '.npmrc'
    if (-not (Test-Path -LiteralPath $userNpmrc)) {
        Write-TextFileNoBom -Path $userNpmrc -Lines @("registry=$registry")
        Write-Ok "已设置 npm 镜像源: $registry（$userNpmrc）"
        return
    }
    $content = @([IO.File]::ReadAllLines($userNpmrc, [Text.Encoding]::UTF8))
    $hasRegistry = $false
    foreach ($line in $content) {
        if ($line -match '^\s*registry\s*=') { $hasRegistry = $true }
    }
    if ($hasRegistry) {
        Write-Info "npm 已配置 registry，保持不变（$userNpmrc）"
    } else {
        $newContent = @($content) + @("registry=$registry")
        Write-TextFileNoBom -Path $userNpmrc -Lines $newContent
        Write-Ok "已追加 npm 镜像源: $registry"
    }
}

# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------
function Test-PostgresRunning {
    param([hashtable]$Spec)
    $dataDir = Join-Path $script:Ctx.Data 'postgres'
    $pgCtl = Join-Path $Spec.Target 'bin\pg_ctl.exe'
    if (-not (Test-Path -LiteralPath $pgCtl)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $dataDir 'postmaster.pid'))) { return $false }
    $r = Invoke-Process -FilePath $pgCtl -Arguments @('-D', $dataDir, 'status') -TimeoutSeconds 30 -AllowFailure
    return ($r.ExitCode -eq 0)
}

function Start-PostgresServer {
    param([hashtable]$Spec)
    $cfg = $Spec.Comp
    $dataDir = Join-Path $script:Ctx.Data 'postgres'
    $pgCtl = Join-Path $Spec.Target 'bin\pg_ctl.exe'
    $logFile = Join-Path $script:Ctx.Logs 'postgres.log'
    if (Test-PostgresRunning -Spec $Spec) {
        Write-Info 'PostgreSQL 已在运行'
        return $true
    }
    # PostgreSQL 官方限制：不允许以管理员（提升权限）身份运行服务端进程
    if (Test-IsAdmin) {
        Write-Warn 'PostgreSQL 拒绝以管理员权限运行服务端（官方安全限制），已跳过本次启动'
        Write-Warn '数据目录已准备就绪，请用普通权限启动它：'
        Write-Warn '  · 双击桌面上的「PostgreSQL-启动」快捷方式（快捷方式以普通权限运行），或'
        Write-Warn "  · 在普通（非管理员）终端里执行 $($script:Ctx.Bin)\pg-start.cmd"
        return $false
    }
    Write-Info "启动 PostgreSQL（数据目录 $dataDir）"
    # 关键：必须用 -InheritConsole（输出直通控制台，不捕获）。
    # pg_ctl start 会派生出常驻的 postgres.exe 并让它继承输出管道；
    # 若脚本捕获其输出，管道在服务端退出前不会关闭，读取会永久阻塞（表现为脚本卡死）。
    $r = Invoke-Process -FilePath $pgCtl -Arguments @('-D', $dataDir, '-l', $logFile, '-w', '-t', '60', 'start') `
        -TimeoutSeconds 180 -InheritConsole -AllowFailure

    # 以“实际能否连上”为准（pg_ctl 的退出码在某些环境下不足以判断）
    $port = Get-EffectivePort -Spec $Spec -Default ([int](Get-ObjectProperty -Object $cfg -Name 'port' -Default 5432))
    $ready = Join-Path $Spec.Target 'bin\pg_isready.exe'
    $readyOk = $false
    if (Test-Path -LiteralPath $ready) {
        for ($i = 1; $i -le 10; $i++) {
            $rr = Invoke-Process -FilePath $ready -Arguments @('-h', '127.0.0.1', '-p', ([string]$port)) -TimeoutSeconds 20 -AllowFailure
            if ($rr.ExitCode -eq 0) { $readyOk = $true; break }
            if ($i -eq 1) { Write-Info '等待 PostgreSQL 就绪...' }
            Start-Sleep -Milliseconds 900
        }
        if (-not $readyOk) { Write-Warn "pg_isready 未就绪: 127.0.0.1:$port" }
    }

    if (-not $readyOk -and -not (Test-PostgresRunning -Spec $Spec)) {
        Write-Err "PostgreSQL 启动失败（pg_ctl 退出码 $($r.ExitCode)，超时: $($r.TimedOut)）"
        if (Test-Path -LiteralPath $logFile) {
            $tail = @([IO.File]::ReadAllLines($logFile, [Text.Encoding]::UTF8) | Select-Object -Last 10)
            foreach ($l in $tail) { Write-Err "  pg: $l" }
        }
        Write-Warn "也可稍后手动启动：$($script:Ctx.Bin)\pg-start.cmd"
        return $false
    }
    Write-Ok "PostgreSQL 已启动（端口 $port）"
    return $true
}

function Stop-PostgresServer {
    param([hashtable]$Spec)
    $dataDir = Join-Path $script:Ctx.Data 'postgres'
    $pgCtl = Join-Path $Spec.Target 'bin\pg_ctl.exe'
    if (-not (Test-Path -LiteralPath (Join-Path $dataDir 'postmaster.pid'))) {
        Write-Info 'PostgreSQL 未在运行'
        return $true
    }
    $r = Invoke-Process -FilePath $pgCtl -Arguments @('-D', $dataDir, '-m', 'fast', '-w', '-t', '60', 'stop') -TimeoutSeconds 180
    if ($r.ExitCode -ne 0) { Write-Warn "PostgreSQL 停止返回 $($r.ExitCode): $($r.StdErr)" ; return $false }
    Write-Ok 'PostgreSQL 已停止'
    return $true
}

function Test-TcpPortFree {
    param([int]$Port, [string]$BindHost = '127.0.0.1')
    try {
        $client = New-Object Net.Sockets.TcpClient
        $async = $client.BeginConnect($BindHost, $Port, $null, $null)
        $ok = $async.AsyncWaitHandle.WaitOne(600)
        $connected = $false
        if ($ok) {
            try { $client.EndConnect($async); $connected = $true } catch { $connected = $false }
        }
        $client.Close()
        return (-not $connected)
    } catch {
        return $true
    }
}

function Configure-Postgres {
    param([Parameter(Mandatory = $true)][hashtable]$Spec)
    $cfg = $Spec.Comp
    $binDir = Join-Path $Spec.Target 'bin'
    $pgCtl = Join-Path $binDir 'pg_ctl.exe'
    $initdb = Join-Path $binDir 'initdb.exe'
    $psql = Join-Path $binDir 'psql.exe'

    $port = [int](Get-ObjectProperty -Object $cfg -Name 'port' -Default 5432)
    $listen = [string](Get-ObjectProperty -Object $cfg -Name 'listenAddresses' -Default 'localhost')
    $superuser = [string](Get-ObjectProperty -Object $cfg -Name 'superuser' -Default 'postgres')
    $password = [string](Get-ObjectProperty -Object $cfg -Name 'password' -Default 'postgres')
    $encoding = [string](Get-ObjectProperty -Object $cfg -Name 'encoding' -Default 'UTF8')
    $locale = [string](Get-ObjectProperty -Object $cfg -Name 'locale' -Default 'C')
    $localeProvider = [string](Get-ObjectProperty -Object $cfg -Name 'localeProvider' -Default '')
    $icuLocale = [string](Get-ObjectProperty -Object $cfg -Name 'icuLocale' -Default '')
    $authMethod = [string](Get-ObjectProperty -Object $cfg -Name 'authMethod' -Default 'scram-sha-256')
    $maxConn = [int](Get-ObjectProperty -Object $cfg -Name 'maxConnections' -Default 100)
    $sharedBuffers = [string](Get-ObjectProperty -Object $cfg -Name 'sharedBuffers' -Default '128MB')
    $timezone = [string](Get-ObjectProperty -Object $cfg -Name 'timezone' -Default 'Asia/Shanghai')
    $databases = @(Get-ObjectProperty -Object $cfg -Name 'databases' -Default @())
    $dataDir = Join-Path $script:Ctx.Data 'postgres'
    $logFile = Join-Path $script:Ctx.Logs 'postgres.log'

    if (-not (Test-Path -LiteralPath $pgCtl)) { throw "找不到 pg_ctl.exe（$binDir）" }

    # ---------------- 0. 端口与实例决策 ----------------
    # 数据目录已初始化 → 沿用上次记录的端口；机器上已有 PostgreSQL 在跑 → 默认不再造第二个实例
    $versionFile = Join-Path $dataDir 'PG_VERSION'
    $initialized = Test-Path -LiteralPath $versionFile
    $marker = Get-ComponentMarker -Target $Spec.Target
    $recordedPort = 0
    $markerUseExisting = $false
    if ($marker -and $marker.extra) {
        if ($marker.extra.port) { $recordedPort = [int]$marker.extra.port }
        if ($marker.extra.useExisting) { $markerUseExisting = [bool]$marker.extra.useExisting }
    }
    $running = Test-PostgresRunning -Spec $Spec
    $createMode = [string](Get-ObjectProperty -Object $cfg -Name 'createInstance' -Default 'auto')
    $portBusy = -not (Test-TcpPortFree -Port $port)

    $skipInstance = $false
    $skipReason = ''
    if ($running -or ($initialized -and $recordedPort -gt 0)) {
        if ($recordedPort -gt 0) { $port = $recordedPort }
    } elseif ($createMode -ieq 'false') {
        $skipInstance = $true
        $skipReason = '配置中 components.postgres.createInstance=false'
    } elseif ($markerUseExisting -and $createMode -ine 'true') {
        $skipInstance = $true
        $skipReason = '上次运行已判定复用机器上已有的 PostgreSQL'
    } elseif ($Spec.Adopted -and $createMode -ine 'true') {
        $skipInstance = $true
        $skipReason = "本工具正在复用机器上已有的 PostgreSQL 安装（$($Spec.Target)）"
    } elseif ($portBusy) {
        $requested = $port
        while ($port -lt ($requested + 20) -and -not (Test-TcpPortFree -Port $port)) { $port++ }
        Write-Warn "端口 $requested 已被占用，本实例改用端口 $port"
    }
    if ($skipInstance) {
        Write-Warn "已跳过创建独立的 PostgreSQL 实例：$skipReason"
        Write-Warn '若希望本工具另行创建一个隔离的开发实例：请设置 components.postgres.createInstance=true，'
        Write-Warn '同时可把 components.postgres.port 设为空闲端口（如 5433）。'
        Set-ComponentMarker -Target $Spec.Target -Key 'postgres' -Version $Spec.Version -Source 'adopted' -Extra @{ port = $port; useExisting = $true }
        return
    }

    # ---------------- 1. 初始化数据目录 ----------------
    if (Test-Path -LiteralPath $versionFile) {
        Write-Info "PostgreSQL 数据目录已初始化: $dataDir"
    } elseif ([bool](Get-ObjectProperty -Object $cfg -Name 'initData' -Default $true)) {
        if ((Test-Path -LiteralPath $dataDir) -and @(Get-ChildItem -LiteralPath $dataDir -Force -ErrorAction SilentlyContinue).Count -gt 0) {
            throw "数据目录 $dataDir 非空且不是有效的 PostgreSQL 数据目录，为避免误删已停止安装。请手工清空后重试。"
        }
        New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
        $pwFile = Join-Path $script:Ctx.Cache '.pgpw'
        [IO.File]::WriteAllText($pwFile, $password, (New-Object Text.UTF8Encoding $false))
        $initArgs = @('-D', $dataDir, '-U', $superuser, '-E', $encoding, '-A', $authMethod, "--pwfile=$pwFile")
        if (-not [string]::IsNullOrWhiteSpace($localeProvider)) {
            $initArgs += @('--locale-provider', $localeProvider)
            if (-not [string]::IsNullOrWhiteSpace($icuLocale)) { $initArgs += @('--icu-locale', $icuLocale) }
        } elseif (-not [string]::IsNullOrWhiteSpace($locale)) {
            $initArgs += @('--locale', $locale)
        }
        Write-Info "初始化 PostgreSQL 数据目录（编码 $encoding，用户 $superuser）"
        $r = Invoke-Process -FilePath $initdb -Arguments $initArgs -TimeoutSeconds 1800
        Remove-Item -LiteralPath $pwFile -Force -ErrorAction SilentlyContinue
        if ($r.ExitCode -ne 0) { throw "initdb 失败（退出码 $($r.ExitCode)）: $($r.StdOut)$($r.StdErr)" }
        Write-Ok 'PostgreSQL 数据目录初始化完成'
    }

    # ---------------- 2. 配置文件 ----------------
    if (Test-Path -LiteralPath $dataDir) {
        $confFile = Join-Path $dataDir 'postgresql.conf'
        Set-ManagedBlock -File $confFile -Id 'postgresql' -Lines @(
            "# 由 JavaDevEnv 管理，修改后重新运行安装脚本会被覆盖",
            "port = $port",
            "listen_addresses = '$listen'",
            "max_connections = $maxConn",
            "shared_buffers = $sharedBuffers",
            "log_destination = 'stderr'",
            "logging_collector = off",
            "lc_messages = 'C'",
            "timezone = '$timezone'"
        )
    }

    # ---------------- 3. 辅助脚本 ----------------
    $binOut = $script:Ctx.Bin
    Write-TextFileNoBom -Path (Join-Path $binOut 'pg-start.cmd') -Lines @(
        '@echo off',
        'setlocal',
        "set `"PGDATA=$dataDir`"",
        "`"$pgCtl`" -D `"%PGDATA%`" -l `"$logFile`" -w -t 60 start",
        'if errorlevel 1 goto pgfail',
        "`"$binDir\pg_isready.exe`" -h 127.0.0.1 -p $port",
        'rem create the development databases if they do not exist yet',
        "`"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -File `"$($script:Ctx.Bin)\pg-ensure-db.ps1`"",
        "echo [OK] PostgreSQL started on port $port.",
        'timeout /t 3 >nul',
        'exit /b 0',
        ':pgfail',
        'echo [ERROR] PostgreSQL failed to start. Log file:',
        "echo   $logFile",
        'pause',
        'exit /b 1'
    )
    Write-TextFileNoBom -Path (Join-Path $binOut 'pg-stop.cmd') -Lines @(
        '@echo off',
        'setlocal',
        "set `"PGDATA=$dataDir`"",
        "`"$pgCtl`" -D `"%PGDATA%`" -m fast -w -t 60 stop",
        'if errorlevel 1 (echo [ERROR] PostgreSQL failed to stop & pause & exit /b 1)',
        'echo [OK] PostgreSQL stopped.',
        'timeout /t 2 >nul',
        'exit /b 0'
    )
    Write-TextFileNoBom -Path (Join-Path $binOut 'pg-status.cmd') -Lines @(
        '@echo off',
        'setlocal',
        "set `"PGDATA=$dataDir`"",
        "`"$pgCtl`" -D `"%PGDATA%`" status",
        'pause'
    )
    # 开机自启专用：静默启动（无 pause、无交互提示、输出丢弃），登录时由「启动」文件夹调用
    Write-TextFileNoBom -Path (Join-Path $binOut 'pg-autostart.cmd') -Lines @(
        '@echo off',
        'setlocal',
        "set `"PGDATA=$dataDir`"",
        "`"$pgCtl`" -D `"%PGDATA%`" -l `"$logFile`" -w -t 60 start >nul 2>&1",
        'if errorlevel 1 exit /b 1',
        "`"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -File `"$($script:Ctx.Bin)\pg-ensure-db.ps1`" >nul 2>&1",
        'exit /b 0'
    )
    Write-TextFileNoBom -Path (Join-Path $binOut 'psql.cmd') -Lines @(
        '@echo off',
        'setlocal',
        "set `"PGPASSWORD=$password`"",
        "`"$psql`" -h 127.0.0.1 -p $port -U $superuser %*"
    )

    # 独立的“确保数据库存在”脚本：pg-start.cmd 与后续运行都会调用它，
    # 这样即使 PostgreSQL 是在稍后用桌面快捷方式（普通权限）启动的，开发库也会被自动创建。
    $ensureScript = Join-Path $binOut 'pg-ensure-db.ps1'
    $dbList = (@($databases) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ', '
    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Write-TextFileBom -Path $ensureScript -Lines @(
        '# 由 JavaDevEnv 生成：确保所需的开发数据库存在（可重复执行）',
        '$ErrorActionPreference = ''Continue''',
        "`$psql = '$psql'",
        "`$port = $port",
        "`$user = '$superuser'",
        "`$password = '$password'",
        "`$encoding = '$encoding'",
        "`$databases = @($dbList)",
        '$env:PGPASSWORD = $password',
        'foreach ($db in $databases) {',
        '    if ([string]::IsNullOrWhiteSpace($db)) { continue }',
        '    $sql = "SELECT 1 FROM pg_database WHERE datname = ''$db''"',
        '    $exists = ((& $psql -h 127.0.0.1 -p $port -U $user -tAc $sql 2>&1) -join '' '').Trim()',
        '    if ($exists -eq ''1'') { Write-Host ("  [跳过] 数据库已存在: " + $db); continue }',
        '    $createSql = "CREATE DATABASE ""$db"" ENCODING ''$encoding''"',
        '    & $psql -h 127.0.0.1 -p $port -U $user -c $createSql | Out-Null',
        '    if ($LASTEXITCODE -eq 0) { Write-Host ("  [完成] 已创建数据库: " + $db) } else { Write-Host ("  [失败] 创建数据库失败: " + $db) }',
        '}'
    )

    $pgIconStart = Get-IconAsset -Name 'pgsql-start.ico'
    if ([string]::IsNullOrWhiteSpace($pgIconStart)) { $pgIconStart = [Environment]::ExpandEnvironmentVariables('%SystemRoot%\System32\shell32.dll,137') }
    $pgIconStop = Get-IconAsset -Name 'pgsql-stop.ico'
    if ([string]::IsNullOrWhiteSpace($pgIconStop)) { $pgIconStop = [Environment]::ExpandEnvironmentVariables('%SystemRoot%\System32\shell32.dll,131') }
    Add-SpecShortcut -Spec $Spec -Item 'pg' -Name 'PostgreSQL-启动' -Target (Join-Path $binOut 'pg-start.cmd') `
        -Icon $pgIconStart
    Add-SpecShortcut -Spec $Spec -Item 'pg' -Name 'PostgreSQL-停止' -Target (Join-Path $binOut 'pg-stop.cmd') `
        -Icon $pgIconStop
    Add-SpecShortcut -Spec $Spec -Item 'pg' -Name 'PostgreSQL 命令行(psql)' -Target (Join-Path $binOut 'psql.cmd') `
        -Icon $psql

    # ---------------- 4. 启动并建库 ----------------
    $startAfter = [bool](Get-ObjectProperty -Object $cfg -Name 'startAfterInstall' -Default $true)
    if ($startAfter) { [void](Start-PostgresServer -Spec $Spec) }

    # 只要实例在运行（本次启动成功，或之前就已运行），就确保数据库存在
    if (Test-PostgresRunning -Spec $Spec) {
        $er = Invoke-Process -FilePath $powershellExe -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ensureScript) -TimeoutSeconds 300 -AllowFailure
        foreach ($line in @(($er.StdOut + $er.StdErr) -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
            Write-Info $line
        }
    }

    # 记录本次实际使用的端口，脚本、快捷方式与连接信息统一以此为准
    $markerSource = 'configured'
    if ($marker -and $marker.source) { $markerSource = [string]$marker.source }
    Set-ComponentMarker -Target $Spec.Target -Key 'postgres' -Version $Spec.Version -Source $markerSource -Extra @{ port = $port }
}

# ---------------------------------------------------------------------------
# Redis
# ---------------------------------------------------------------------------
function Test-RedisRunning {
    param([hashtable]$Spec)
    $cfg = $Spec.Comp
    $port = Get-EffectivePort -Spec $Spec -Default ([int](Get-ObjectProperty -Object $cfg -Name 'port' -Default 6379))
    $cli = Join-Path $Spec.Target 'redis-cli.exe'
    if (-not (Test-Path -LiteralPath $cli)) { return $false }
    $auth = @()
    $password = [string](Get-ObjectProperty -Object $cfg -Name 'password' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($password)) { $auth = @('-a', $password, '--no-auth-warning') }
    $r = Invoke-Process -FilePath $cli -Arguments (@('-h', '127.0.0.1', '-p', "$port") + $auth + @('ping')) -TimeoutSeconds 20 -AllowFailure
    return (($r.StdOut + $r.StdErr) -match 'PONG')
}

function Start-RedisServer {
    param([hashtable]$Spec, [hashtable]$Conf)
    $exe = Join-Path $Spec.Target 'redis-server.exe'
    $confFile = Join-Path $Spec.Target 'redis-dev.conf'
    if (Test-RedisRunning -Spec $Spec) { Write-Info 'Redis 已在运行'; return $true }
    Write-Info "启动 Redis（$confFile）"
    if ($script:Options -and $script:Options.DryRun) { return $true }
    # 注意：Windows 版 Redis 基于 MSYS2，命令行里的 Windows 绝对路径会被改写成 "/E:\..." 而打不开，
    # 因此这里把工作目录设为安装目录并只传配置文件名（相对路径）。
    $psArgs = @{
        FilePath         = $exe
        ArgumentList     = (ConvertTo-ProcessArgument (Split-Path -Leaf $confFile))
        WorkingDirectory = $Spec.Target
        WindowStyle      = 'Minimized'
        PassThru         = $true
    }
    try { Start-Process @psArgs | Out-Null } catch { Write-Err "Redis 启动失败: $($_.Exception.Message)"; return $false }
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 700
        if (Test-RedisRunning -Spec $Spec) { Write-Ok 'Redis 已启动'; return $true }
    }
    Write-Err 'Redis 启动超时，请检查日志'
    return $false
}

function Stop-RedisServer {
    param([hashtable]$Spec)
    $cfg = $Spec.Comp
    $port = Get-EffectivePort -Spec $Spec -Default ([int](Get-ObjectProperty -Object $cfg -Name 'port' -Default 6379))
    $password = [string](Get-ObjectProperty -Object $cfg -Name 'password' -Default '')
    $cli = Join-Path $Spec.Target 'redis-cli.exe'
    $auth = @()
    if (-not [string]::IsNullOrWhiteSpace($password)) { $auth = @('-a', $password, '--no-auth-warning') }
    $r = Invoke-Process -FilePath $cli -Arguments (@('-h', '127.0.0.1', '-p', "$port") + $auth + @('shutdown', 'nosave')) -TimeoutSeconds 30 -AllowFailure
    Start-Sleep -Milliseconds 600
    if (Test-RedisRunning -Spec $Spec) {
        Write-Warn 'Redis 仍在运行，请手工检查'
        return $false
    }
    Write-Ok 'Redis 已停止'
    return $true
}

function Configure-Redis {
    param([Parameter(Mandatory = $true)][hashtable]$Spec)
    $cfg = $Spec.Comp
    $exe = Join-Path $Spec.Target 'redis-server.exe'
    $cli = Join-Path $Spec.Target 'redis-cli.exe'
    $port = [int](Get-ObjectProperty -Object $cfg -Name 'port' -Default 6379)
    $bindAddr = [string](Get-ObjectProperty -Object $cfg -Name 'bind' -Default '127.0.0.1')
    $password = [string](Get-ObjectProperty -Object $cfg -Name 'password' -Default '')
    $maxmemory = [string](Get-ObjectProperty -Object $cfg -Name 'maxmemory' -Default '512mb')
    $policy = [string](Get-ObjectProperty -Object $cfg -Name 'maxmemoryPolicy' -Default 'allkeys-lru')
    $appendonly = [bool](Get-ObjectProperty -Object $cfg -Name 'appendonly' -Default $true)
    $dataDir = Join-Path $script:Ctx.Data 'redis'
    $logFile = Join-Path $script:Ctx.Logs 'redis.log'
    if (-not (Test-Path -LiteralPath $exe)) { throw "找不到 redis-server.exe（$($Spec.Target)）" }
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null

    # 端口决策：本实例已在运行时沿用记录端口；否则被占用则自动顺延 / 或复用已有实例
    $marker = Get-ComponentMarker -Target $Spec.Target
    $recordedPort = 0
    $markerUseExisting = $false
    if ($marker -and $marker.extra) {
        if ($marker.extra.port) { $recordedPort = [int]$marker.extra.port }
        if ($marker.extra.useExisting) { $markerUseExisting = [bool]$marker.extra.useExisting }
    }
    $createMode = [string](Get-ObjectProperty -Object $cfg -Name 'createInstance' -Default 'auto')
    $running = Test-RedisRunning -Spec $Spec
    $portBusy = -not (Test-TcpPortFree -Port $port)
    $ours = ($recordedPort -gt 0 -and -not $markerUseExisting)

    $skipInstance = $false
    if ($running -and $recordedPort -gt 0) {
        $port = $recordedPort
    } elseif ($ours) {
        $port = $recordedPort
    } elseif ($createMode -ieq 'false') {
        $skipInstance = $true
    } elseif ($markerUseExisting -and $createMode -ine 'true') {
        $skipInstance = $true
    } elseif ($Spec.Adopted -and $createMode -ine 'true') {
        $skipInstance = $true
    } elseif ($portBusy) {
        $requested = $port
        while ($port -lt ($requested + 20) -and -not (Test-TcpPortFree -Port $port)) { $port++ }
        Write-Warn "端口 $requested 已被占用，Redis 实例改用端口 $port（如需固定请修改 components.redis.port）"
    }
    if ($skipInstance) {
        Write-Warn "已跳过创建独立的 Redis 实例（复用机器上已有的 Redis 安装：$($Spec.Target)）"
        Write-Warn '若希望本工具另行创建一个隔离实例：请设置 components.redis.createInstance=true，并把 components.redis.port 设为空闲端口。'
        Set-ComponentMarker -Target $Spec.Target -Key 'redis' -Version $Spec.Version -Source 'adopted' -Extra @{ port = $port; useExisting = $true }
        return
    }

    $dataPath = $dataDir -replace '\\', '/'
    $logPath = $logFile -replace '\\', '/'
    $lines = New-Object Collections.ArrayList
    [void]$lines.Add('# 由 JavaDevEnv 生成，重新运行安装脚本会覆盖本文件')
    [void]$lines.Add("bind $bindAddr")
    [void]$lines.Add("port $port")
    [void]$lines.Add('protected-mode yes')
    [void]$lines.Add("dir `"$dataPath`"")
    [void]$lines.Add("logfile `"$logPath`"")
    [void]$lines.Add('dbfilename dump.rdb')
    [void]$lines.Add('save 900 1')
    [void]$lines.Add("maxmemory $maxmemory")
    [void]$lines.Add("maxmemory-policy $policy")
    if ($appendonly) {
        [void]$lines.Add('appendonly yes')
        [void]$lines.Add('appendfilename "appendonly.aof"')
        [void]$lines.Add('appendfsync everysec')
    } else {
        [void]$lines.Add('appendonly no')
    }
    if (-not [string]::IsNullOrWhiteSpace($password)) { [void]$lines.Add("requirepass $password") }
    $confFile = Join-Path $Spec.Target 'redis-dev.conf'
    Write-TextFileNoBom -Path $confFile -Lines $lines.ToArray()

    $authArg = ''
    if (-not [string]::IsNullOrWhiteSpace($password)) { $authArg = "-a $password --no-auth-warning" }

    $binOut = $script:Ctx.Bin
    Write-TextFileNoBom -Path (Join-Path $binOut 'redis-start.cmd') -Lines @(
        '@echo off',
        'setlocal',
        "cd /d `"$($Spec.Target)`"",
        "start `"Redis $port`" /min `"$exe`" `"redis-dev.conf`"",
        'timeout /t 2 >nul',
        "`"$cli`" -h 127.0.0.1 -p $port $authArg ping",
        'if errorlevel 1 (echo [ERROR] Redis failed to start & pause & exit /b 1)',
        'echo [OK] Redis started.',
        'timeout /t 2 >nul',
        'exit /b 0'
    )
    Write-TextFileNoBom -Path (Join-Path $binOut 'redis-stop.cmd') -Lines @(
        '@echo off',
        'setlocal',
        "`"$cli`" -h 127.0.0.1 -p $port $authArg shutdown nosave",
        'echo [OK] Redis stopped.',
        'timeout /t 2 >nul',
        'exit /b 0'
    )
    Write-TextFileNoBom -Path (Join-Path $binOut 'redis-cli.cmd') -Lines @(
        '@echo off',
        'setlocal',
        "`"$cli`" -h 127.0.0.1 -p $port $authArg %*"
    )
    # 开机自启专用：静默拉起（Redis 的控制台窗口保持最小化，关掉它 = 停掉 Redis）
    Write-TextFileNoBom -Path (Join-Path $binOut 'redis-autostart.cmd') -Lines @(
        '@echo off',
        'setlocal',
        "cd /d `"$($Spec.Target)`"",
        "start `"Redis $port`" /min `"$exe`" `"redis-dev.conf`"",
        'exit /b 0'
    )

    $redisIconStart = Get-IconAsset -Name 'redis-start.ico'
    if ([string]::IsNullOrWhiteSpace($redisIconStart)) { $redisIconStart = [Environment]::ExpandEnvironmentVariables('%SystemRoot%\System32\shell32.dll,137') }
    $redisIconStop = Get-IconAsset -Name 'redis-stop.ico'
    if ([string]::IsNullOrWhiteSpace($redisIconStop)) { $redisIconStop = [Environment]::ExpandEnvironmentVariables('%SystemRoot%\System32\shell32.dll,131') }
    Add-SpecShortcut -Spec $Spec -Item 'redis' -Name 'Redis-启动' -Target (Join-Path $binOut 'redis-start.cmd') `
        -Icon $redisIconStart
    Add-SpecShortcut -Spec $Spec -Item 'redis' -Name 'Redis-停止' -Target (Join-Path $binOut 'redis-stop.cmd') `
        -Icon $redisIconStop
    Add-SpecShortcut -Spec $Spec -Item 'redis' -Name 'Redis 命令行(redis-cli)' -Target (Join-Path $binOut 'redis-cli.cmd') `
        -Icon $cli

    if ([bool](Get-ObjectProperty -Object $cfg -Name 'startAfterInstall' -Default $true)) {
        [void](Start-RedisServer -Spec $Spec -Conf $cfg)
    }

    $markerSource = 'configured'
    if ($marker -and $marker.source) { $markerSource = [string]$marker.source }
    Set-ComponentMarker -Target $Spec.Target -Key 'redis' -Version $Spec.Version -Source $markerSource -Extra @{ port = $port }
}

# ---------------------------------------------------------------------------
# DBeaver / HeidiSQL
# ---------------------------------------------------------------------------
function Configure-Dbeaver {
    param([Parameter(Mandatory = $true)][hashtable]$Spec)
    $cfg = $Spec.Comp
    $portable = [bool](Get-ObjectProperty -Object $cfg -Name 'portable' -Default $true)
    $dbeaverArgs = ''
    if ($portable) {
        $ws = Join-Path $script:Ctx.Data 'dbeaver-workspace'
        New-Item -ItemType Directory -Path $ws -Force | Out-Null
        $dbeaverArgs = '-data "' + $ws + '"'
    }
    Add-SpecShortcut -Spec $Spec -Item 'dbeaver' -Name 'DBeaver' -Target $Spec.ProbePath -Arguments $dbeaverArgs -Icon $Spec.ProbePath
}

function Configure-HeidiSql {
    param([Parameter(Mandatory = $true)][hashtable]$Spec)
    $cfg = $Spec.Comp
    if ([bool](Get-ObjectProperty -Object $cfg -Name 'portable' -Default $true)) {
        $settingsFile = Join-Path $Spec.Target 'portable_settings.txt'
        if (-not (Test-Path -LiteralPath $settingsFile)) {
            Write-TextFileNoBom -Path $settingsFile -Lines @(
                '; HeidiSQL portable settings (created by JavaDevEnv)',
                '; 该文件存在时 HeidiSQL 会把配置保存在程序目录，实现免安装',
                '',
                '[Servers]',
                ''
            )
            Write-Ok '已启用 HeidiSQL 便携模式'
        }
    }
    Add-SpecShortcut -Spec $Spec -Item 'heidisql' -Name 'HeidiSQL' -Target $Spec.ProbePath -Icon $Spec.ProbePath
}

# ---------------------------------------------------------------------------
# WindTerm / Apifox / Tiny RDM
# ---------------------------------------------------------------------------
function Configure-WindTerm {
    # WindTerm 便携版：首次启动会弹一次「选择 profiles 目录」，选默认（用户主目录）即可；
    # 会话数据保存在所选目录的 .wind 子目录里，升级替换程序目录不影响会话。
    param([Parameter(Mandatory = $true)][hashtable]$Spec)
    if ([string]::IsNullOrWhiteSpace($Spec.ProbePath) -or -not (Test-Path -LiteralPath $Spec.ProbePath)) { return }
    Add-SpecShortcut -Spec $Spec -Item 'windterm' -Name 'WindTerm' -Target $Spec.ProbePath -Icon $Spec.ProbePath
}

function Configure-Apifox {
    param([Parameter(Mandatory = $true)][hashtable]$Spec)
    if ([string]::IsNullOrWhiteSpace($Spec.ProbePath) -or -not (Test-Path -LiteralPath $Spec.ProbePath)) { return }
    Add-SpecShortcut -Spec $Spec -Item 'apifox' -Name 'Apifox' -Target $Spec.ProbePath -Icon $Spec.ProbePath
}

function Configure-TinyRdm {
    param([Parameter(Mandatory = $true)][hashtable]$Spec)
    if ([string]::IsNullOrWhiteSpace($Spec.ProbePath) -or -not (Test-Path -LiteralPath $Spec.ProbePath)) { return }
    Add-SpecShortcut -Spec $Spec -Item 'tinyrdm' -Name 'Tiny RDM' -Target $Spec.ProbePath -Icon $Spec.ProbePath
}

# ---------------------------------------------------------------------------
# DSH（DeepSeek Harness）
# ---------------------------------------------------------------------------
function Configure-Dsh {
    # 桌面端：GUI 程序，快捷方式直接指向 exe。
    # 安装程序自己通常已经在桌面建了「DeepSeek Harness.lnk」，这里先查重，避免出现两个图标。
    param([hashtable]$Spec)
    if ([string]::IsNullOrWhiteSpace($Spec.ProbePath) -or -not (Test-Path -LiteralPath $Spec.ProbePath)) {
        Write-Warn "未找到 DSH 桌面端程序（$($Spec.Target)）"
        return
    }
    Write-Info "DSH 桌面端程序: $($Spec.ProbePath)"
    if ([bool](Get-ConfigValue -Path 'shortcuts.desktop' -Default $true)) {
        $desk = Get-ShortcutDirectory -Kind 'Desktop'
        $exists = Find-ShortcutByTarget -Directory $desk -TargetPath $Spec.ProbePath
        if ($exists) {
            Write-Info "桌面已存在指向该程序的快捷方式（$([IO.Path]::GetFileName($exists))），跳过创建"
            return
        }
    }
    Add-SpecShortcut -Spec $Spec -Item 'dsh' -Name 'DSH 桌面端' -Target $Spec.ProbePath -Icon $Spec.ProbePath
}

function Configure-DshCli {
    # 命令行版 dsh：dsh 必须带 profile 名（dsh web / dsh tui / dsh headless "..."），
    # 直接双击 dsh.cmd 会立刻以 "error: --profile <name> is required" 退出、窗口一闪而过。
    # 所以这里生成一个启动器：设置好 PATH、给出用法、默认进 web，并且让窗口留在原地。
    param([hashtable]$Spec)
    $root = $script:Ctx.Root
    $globalDir = $Spec.Target
    $shim = Join-Path $globalDir 'dsh.cmd'
    if (-not (Test-Path -LiteralPath $shim)) { $shim = [string]$Spec.ProbePath }
    if ([string]::IsNullOrWhiteSpace($shim) -or -not (Test-Path -LiteralPath $shim)) {
        Write-Warn '未找到 dsh.cmd，跳过命令行启动器生成'
        return
    }

    $nodeDir = ''
    $nodeSpec = @($script:Catalog | Where-Object { $_.Key -eq 'node' })[0]
    if ($nodeSpec -and (Test-Path -LiteralPath $nodeSpec.Target)) { $nodeDir = $nodeSpec.Target }
    $pathParts = New-Object Collections.ArrayList
    if ($nodeDir) { [void]$pathParts.Add($nodeDir) }
    [void]$pathParts.Add($globalDir)

    $launcher = Join-Path $script:Ctx.Bin 'dsh-cli.cmd'
    $envCmd = Join-Path $root 'env.cmd'
    # 注意：.cmd 一律用 ASCII 输出，避免在 GBK/UTF-8 代码页之间出现乱码
    $lines = @(
        '@echo off',
        'chcp 65001 >nul 2>&1',
        'setlocal',
        "if exist `"$envCmd`" call `"$envCmd`"",
        # 注意：数组字面量里的 "+" 拼接必须整体加括号，否则逗号优先级更高，会把一行拆成三个元素
        ('set "PATH=' + (($pathParts.ToArray()) -join ';') + ';%PATH%"'),
        "if not exist `"$shim`" goto missing",
        'if not "%~1"=="" goto run',
        'echo dsh requires a profile name. Common ones:',
        'echo    dsh web                 boot the web app (same UI as the desktop app)',
        'echo    dsh tui                 boot the terminal UI',
        'echo    dsh headless "task"     answer one task and exit',
        'echo    dsh -h                  full usage',
        'echo.',
        'set "PROFILE="',
        'set /p "PROFILE=Profile [web]: "',
        'if "%PROFILE%"=="" set "PROFILE=web"',
        "call `"$shim`" %PROFILE%",
        'goto end',
        ':run',
        "call `"$shim`" %*",
        'goto end',
        ':missing',
        "echo [ERROR] dsh not found: $shim",
        ':end',
        'echo.',
        'echo dsh exited. This window stays open on purpose.'
    )
    Write-TextFileNoBom -Path $launcher -Lines $lines
    Write-Ok "已生成 dsh 命令行启动器: $launcher"

    $cmdExe = [Environment]::ExpandEnvironmentVariables('%SystemRoot%\System32\cmd.exe')
    Add-SpecShortcut -Spec $Spec -Item 'dsh-cli' -Name 'DSH 命令行' -Target $cmdExe `
        -Arguments (Get-CmdKArguments -ScriptPath $launcher) -Icon $cmdExe
}

# ---------------------------------------------------------------------------
# 全局辅助脚本 / 环境脚本 / 连接信息
# ---------------------------------------------------------------------------
function Write-EnvironmentScripts {
    param([array]$Catalog)
    if ($script:Options -and $script:Options.NoEnv) { return }
    if (-not [bool](Get-ConfigValue -Path 'env.writeEnvScripts' -Default $true)) { return }

    $root = $script:Ctx.Root
    $sets = New-Object Collections.ArrayList      # 名称=值
    $paths = New-Object Collections.ArrayList
    foreach ($spec in @($Catalog)) {
        if ($spec.Status -eq 'failed' -or $spec.Status -eq 'skipped') { continue }
        if (-not (Test-Path -LiteralPath $spec.Target)) { continue }
        foreach ($name in @($spec.EnvVars.Keys)) {
            if ($name -eq 'JAVA_HOME' -and -not $spec.IsDefaultJdk) { continue }
            $rel = [string]$spec.EnvVars[$name]
            $value = $spec.Target
            if ($rel -and $rel -ne '.') { $value = Join-Path $spec.Target $rel }
            [void]$sets.Add(@{ Name = $name; Value = $value })
        }
        if ($spec.AddToPath) {
            foreach ($rel in @($spec.PathEntries)) {
                $dir = $spec.Target
                if ($rel -and $rel -ne '.') { $dir = Join-Path $spec.Target $rel }
                if (Test-Path -LiteralPath $dir) { [void]$paths.Add($dir) }
            }
        }
    }

    $mavenOpts = [string](Get-ConfigValue -Path 'env.mavenOpts' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($mavenOpts)) { [void]$sets.Add(@{ Name = 'MAVEN_OPTS'; Value = $mavenOpts }) }

    $cmdLines = New-Object Collections.ArrayList
    [void]$cmdLines.Add('@echo off')
    [void]$cmdLines.Add('rem JavaDevEnv: environment for the current window only')
    foreach ($s in $sets) { [void]$cmdLines.Add("set `"$($s.Name)=$($s.Value)`"") }
    if ($paths.Count -gt 0) {
        [void]$cmdLines.Add('set "PATH=' + (($paths.ToArray()) -join ';') + ';%PATH%"')
    }
    Write-TextFileNoBom -Path (Join-Path $root 'env.cmd') -Lines $cmdLines.ToArray()

    $psLines = New-Object Collections.ArrayList
    [void]$psLines.Add('# JavaDevEnv: 在当前 PowerShell 会话中生效（. .\env.ps1）')
    foreach ($s in $sets) {
        [void]$psLines.Add('$env:' + $s.Name + " = '" + ([string]$s.Value).Replace("'", "''") + "'")
    }
    if ($paths.Count -gt 0) {
        [void]$psLines.Add('$env:PATH = "' + (($paths.ToArray()) -join ';') + ';$env:PATH"')
    }
    Write-TextFileBom -Path (Join-Path $root 'env.ps1') -Lines $psLines.ToArray()

    $cmdExe = [Environment]::ExpandEnvironmentVariables('%SystemRoot%\System32\cmd.exe')
    $devShell = Join-Path $script:Ctx.Bin 'devshell.cmd'
    Write-TextFileNoBom -Path $devShell -Lines @(
        '@echo off',
        "call `"$root\env.cmd`"",
        'title JavaDevEnv Shell',
        'echo JavaDevEnv shell ready. Type "java -version" to verify.'
    )
    $shellCmd = Join-Path $script:Ctx.Bin 'shell.cmd'
    Write-TextFileNoBom -Path $shellCmd -Lines @(
        '@echo off',
        "call `"$root\env.cmd`"",
        'cmd /k'
    )

    # 自检 / 卸载入口
    $setup = Join-Path $script:Ctx.ScriptRoot 'Setup-JavaDevEnv.ps1'
    foreach ($pair in @(@('status.cmd', 'status'), @('doctor.cmd', 'doctor'))) {
        Write-TextFileNoBom -Path (Join-Path $script:Ctx.Bin $pair[0]) -Lines @(
            '@echo off',
            'chcp 65001 >nul 2>&1',
            "`"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -File `"$setup`" -Action $($pair[1])",
            'pause'
        )
    }
    Write-Ok "已生成环境脚本: $root\env.cmd、$root\env.ps1"
    return @{ Sets = $sets.ToArray(); Paths = $paths.ToArray(); DevShell = $devShell; ShellCmd = $shellCmd }
}

function New-DbInfoFile {
    param([array]$Catalog)
    $root = $script:Ctx.Root
    $lines = New-Object Collections.ArrayList
    [void]$lines.Add('Java 开发环境 - 数据库与中间件连接信息')
    [void]$lines.Add('生成时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    [void]$lines.Add('')

    foreach ($spec in @($Catalog | Where-Object { $_.Key -eq 'postgres' })) {
        $cfg = $spec.Comp
        $port = [int](Get-ObjectProperty -Object $cfg -Name 'port' -Default 5432)
        $marker = Get-ComponentMarker -Target $spec.Target
        $useExisting = $false
        if ($marker -and $marker.extra) {
            if ($marker.extra.port) { $port = [int]$marker.extra.port }
            if ($marker.extra.useExisting) { $useExisting = [bool]$marker.extra.useExisting }
        }
        $user = [string](Get-ObjectProperty -Object $cfg -Name 'superuser' -Default 'postgres')
        $pwd = [string](Get-ObjectProperty -Object $cfg -Name 'password' -Default 'postgres')
        $dbs = @(Get-ObjectProperty -Object $cfg -Name 'databases' -Default @())
        $db = ''
        if ($dbs.Count -gt 0) { $db = [string]$dbs[0] }
        if ([string]::IsNullOrWhiteSpace($db)) { $db = 'postgres' }
        [void]$lines.Add('== PostgreSQL ==')
        [void]$lines.Add("  主机/端口 : 127.0.0.1:$port")
        if ($useExisting) {
            [void]$lines.Add('  说明      : 复用机器上已安装的 PostgreSQL（本工具未创建独立实例）')
            [void]$lines.Add("  安装目录  : $($spec.Target)")
            [void]$lines.Add('             账号/密码/数据库请以该实例自身的设置为准（下面按配置填写，仅供参考）')
        }
        [void]$lines.Add("  用户名    : $user")
        [void]$lines.Add("  密码      : $pwd")
        [void]$lines.Add("  数据库    : " + ($dbs -join ', '))
        [void]$lines.Add("  JDBC URL  : jdbc:postgresql://127.0.0.1:$port/$db")
        if ($useExisting) {
            [void]$lines.Add("  命令行    : $($spec.Target)\bin\psql.exe -h 127.0.0.1 -p $port -U $user")
        } else {
            [void]$lines.Add("  命令行    : $root\bin\psql.cmd  （或 psql -h 127.0.0.1 -p $port -U $user）")
        }
        [void]$lines.Add('  Spring Boot:')
        [void]$lines.Add("    spring.datasource.url=jdbc:postgresql://127.0.0.1:$port/$db")
        [void]$lines.Add("    spring.datasource.username=$user")
        [void]$lines.Add("    spring.datasource.password=$pwd")
        [void]$lines.Add('')
    }
    foreach ($spec in @($Catalog | Where-Object { $_.Key -eq 'redis' })) {
        $cfg = $spec.Comp
        $port = [int](Get-ObjectProperty -Object $cfg -Name 'port' -Default 6379)
        $marker = Get-ComponentMarker -Target $spec.Target
        $useExisting = $false
        if ($marker -and $marker.extra) {
            if ($marker.extra.port) { $port = [int]$marker.extra.port }
            if ($marker.extra.useExisting) { $useExisting = [bool]$marker.extra.useExisting }
        }
        $pwd = [string](Get-ObjectProperty -Object $cfg -Name 'password' -Default '')
        if ([string]::IsNullOrWhiteSpace($pwd)) { $pwd = '(未设置)' }
        [void]$lines.Add('== Redis ==')
        [void]$lines.Add("  主机/端口 : 127.0.0.1:$port")
        [void]$lines.Add("  密码      : $pwd")
        if ($useExisting) {
            [void]$lines.Add('  说明      : 复用机器上已有的 Redis（本工具未创建独立实例）')
        } else {
            [void]$lines.Add("  配置文件  : $($spec.Target)\redis-dev.conf")
            [void]$lines.Add("  命令行    : $root\bin\redis-cli.cmd")
        }
        [void]$lines.Add('  Spring Boot:')
        [void]$lines.Add('    spring.data.redis.host=127.0.0.1')
        [void]$lines.Add("    spring.data.redis.port=$port")
        if (-not [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty -Object $cfg -Name 'password' -Default ''))) {
            [void]$lines.Add("    spring.data.redis.password=$pwd")
        }
        [void]$lines.Add('')
    }
    [void]$lines.Add('提示: 使用 DBeaver / HeidiSQL 新建连接时按上面的信息填写即可。')
    $file = Join-Path $root '数据库连接信息.txt'
    Write-TextFileBom -Path $file -Lines $lines.ToArray()
    return $file
}

function Register-Autostart {
    # 登录自启（「启动」文件夹方案，全程不需要管理员权限）：
    #   - PostgreSQL / Redis：指向 bin 下专用的静默启动脚本（pg-autostart.cmd / redis-autostart.cmd）
    #   - DSH 桌面端：直接指向 DeepSeek Harness.exe（GUI 程序，没有控制台窗口问题）
    # 语义：components.<key>.autostart=true 且目标存在 -> 创建/刷新；autostart=false -> 清掉旧条目。
    # 因此「改配置后重跑 install.cmd / autostart」即可切换自启开关。
    param([array]$Catalog)
    $startup = [Environment]::GetFolderPath('Startup')
    if ([string]::IsNullOrWhiteSpace($startup)) {
        Write-Warn '无法定位「启动」文件夹，跳过开机自启配置'
        return 0
    }
    $known = @(
        @{ Key = 'postgres'; Name = 'JavaDevEnv-PostgreSQL'; Label = 'PostgreSQL'; IconName = 'pgsql-start.ico' },
        @{ Key = 'redis'; Name = 'JavaDevEnv-Redis'; Label = 'Redis'; IconName = 'redis-start.ico' },
        @{ Key = 'dsh'; Name = 'JavaDevEnv-DSH'; Label = 'DSH 桌面端'; IconName = '' }
    )
    $count = 0
    foreach ($k in @($known)) {
        $spec = @($Catalog | Where-Object { $_.Key -eq $k.Key })[0]
        $enabled = $false
        if ($spec -and $spec.Comp) { $enabled = [bool](Get-ObjectProperty -Object $spec.Comp -Name 'autostart' -Default $false) }
        $lnk = Join-Path $startup ($k.Name + '.lnk')
        if (-not $enabled) {
            if (Test-Path -LiteralPath $lnk) {
                if (Remove-Shortcut -Path $lnk) {
                    Write-Info "已移除开机自启: $($k.Label)（components.$($k.Key).autostart=false）"
                }
            }
            continue
        }
        $target = ''
        $winStyle = 7
        switch ($k.Key) {
            'postgres' { $target = Join-Path $script:Ctx.Bin 'pg-autostart.cmd' }
            'redis' { $target = Join-Path $script:Ctx.Bin 'redis-autostart.cmd' }
            'dsh' {
                $target = [string]$spec.ProbePath
                $winStyle = 1   # GUI 程序，正常窗口即可
            }
        }
        if ([string]::IsNullOrWhiteSpace($target) -or -not (Test-Path -LiteralPath $target)) {
            Write-Warn "开机自启跳过（$($k.Label)）：启动目标不存在（$target）；请先完成安装再重跑"
            continue
        }
        $icon = ''
        if (-not [string]::IsNullOrWhiteSpace($k.IconName)) { $icon = Get-IconAsset -Name $k.IconName }
        if ([string]::IsNullOrWhiteSpace($icon)) { $icon = $target }
        if (New-Shortcut -Path $lnk -TargetPath $target -WorkingDirectory $script:Ctx.Bin `
                -IconLocation $icon -Description "JavaDevEnv $($k.Label) 登录自启" -WindowStyle $winStyle) {
            $count++
        }
    }
    if ($count -gt 0) {
        Write-Ok "已设置 $count 个开机自启项（登录后自动拉起；可在 任务管理器 > 启动应用 里禁用）"
    }
    return $count
}

function Unregister-Autostart {
    # 卸载时清理「启动」文件夹里由本工具创建的自启项（不看配置开关，一律移除）
    param([string[]]$Names = @('JavaDevEnv-PostgreSQL', 'JavaDevEnv-Redis', 'JavaDevEnv-DSH'))
    $startup = [Environment]::GetFolderPath('Startup')
    if ([string]::IsNullOrWhiteSpace($startup)) { return 0 }
    $removed = 0
    foreach ($name in @($Names)) {
        $lnk = Join-Path $startup ($name + '.lnk')
        if (Test-Path -LiteralPath $lnk) {
            if (Remove-Shortcut -Path $lnk) { $removed++ }
        }
    }
    return $removed
}
