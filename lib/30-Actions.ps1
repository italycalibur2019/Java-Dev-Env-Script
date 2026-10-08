# ===========================================================================
#  30-Actions.ps1  —  安装 / 状态 / 自检 / 卸载 / 报告
# ===========================================================================

# ---------------------------------------------------------------------------
# 控制台排版（中英文混排对齐）
# ---------------------------------------------------------------------------
function Get-DisplayWidth {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    $width = 0
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if (($code -ge 0x1100 -and $code -le 0x115F) -or
            ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFE30 -and $code -le 0xFE6F) -or
            ($code -ge 0xFF00 -and $code -le 0xFF60) -or
            ($code -ge 0xFFE0 -and $code -le 0xFFE6)) {
            $width += 2
        } else {
            $width += 1
        }
    }
    return $width
}

function Format-PadRight {
    param([string]$Text, [int]$Width)
    $t = [string]$Text
    $diff = $Width - (Get-DisplayWidth -Text $t)
    if ($diff -le 0) { return $t }
    return $t + (' ' * $diff)
}

function Write-TableRow {
    param([string]$Col1, [string]$Col2, [string]$Col3, [string]$Color = 'Gray', [int]$W1 = 30, [int]$W2 = 12)
    $line = '  ' + (Format-PadRight -Text $Col1 -Width $W1) + ' ' + (Format-PadRight -Text $Col2 -Width $W2) + ' ' + $Col3
    Write-Host $line -ForegroundColor $Color
}

function Get-StatusText {
    param([string]$Status)
    switch ($Status) {
        'installed' { return '已安装' }
        'adopted' { return '复用已有' }
        'skipped' { return '已存在' }
        'failed' { return '失败' }
        'missing' { return '未安装' }
        default { return $Status }
    }
}

function Get-StatusColor {
    param([string]$Status)
    switch ($Status) {
        'installed' { return 'Green' }
        'adopted' { return 'Cyan' }
        'skipped' { return 'DarkGray' }
        'failed' { return 'Red' }
        'missing' { return 'DarkYellow' }
        default { return 'Gray' }
    }
}

# ---------------------------------------------------------------------------
# 组件选择
# ---------------------------------------------------------------------------
function Resolve-SelectedComponents {
    param([hashtable]$Config, [array]$Catalog, [string[]]$Components, [string]$Profile)
    if (-not $Catalog) { return @() }
    $selected = $null
    if ($Components -and $Components.Count -gt 0) {
        $selected = @($Components)
    } elseif (-not [string]::IsNullOrWhiteSpace($Profile)) {
        $profiles = Get-ConfigValue -Path 'profiles' -Default @{}
        if ($profiles -is [hashtable] -and $profiles.ContainsKey($Profile)) {
            $selected = @($profiles[$Profile])
        }
    }
    if (-not $selected -or $selected.Count -eq 0) { return $Catalog }
    if ($selected -contains '*') { return $Catalog }

    $keys = New-Object Collections.ArrayList
    foreach ($s in $selected) { [void]$keys.Add([string]$s) }
    # 补齐依赖
    foreach ($spec in @($Catalog)) {
        if ($keys -contains $spec.Key -and $spec.Requires -and -not ($keys -contains $spec.Requires)) {
            [void]$keys.Add($spec.Requires)
            Write-Info "自动补充依赖组件: $($spec.Requires)（$($spec.Name) 需要）"
        }
    }
    # 支持用组件 key（jdk21）或分组名（jdk）来选择，例如 -Components jdk 会选中所有 JDK 版本
    return @(@($Catalog) | Where-Object {
            if ($null -eq $_) { return $false }
            if ($keys -contains $_.Key) { return $true }
            if ($_.ContainsKey('Group') -and $_.Group -and ($keys -contains $_.Group)) { return $true }
            return $false
        })
}

function Show-InteractiveMenu {
    param([array]$Catalog, [hashtable]$Config)
    Write-Section '交互式选择（直接回车 = 使用推荐配置）'
    $index = 0
    $keys = @()
    foreach ($spec in @($Catalog)) {
        $index++
        $keys += $spec.Key
        $mark = '  '
        if ($spec.Group -in @('jdk', 'build', 'base', 'database', 'dbtool', 'ide', 'dsh', 'ssh', 'apitool', 'redisgui')) { $mark = ' *' }
        Write-TableRow -Col1 "$index) $($spec.Name)" -Col2 $mark -Col3 '' -Color 'Gray' -W1 44 -W2 4
    }
    Write-Host ''
    Write-Host '  * 表示推荐安装；可输入编号（逗号分隔，支持 1,3,5 或 2-4），n = 全部不装，回车 = 全部安装' -ForegroundColor DarkGray
    $answer = Read-Host '请选择'
    if ([string]::IsNullOrWhiteSpace($answer)) { return $keys }

    $picked = New-Object Collections.ArrayList
    foreach ($part in ($answer -split ',')) {
        $p = $part.Trim()
        if ($p -match '^\d+$') {
            $n = [int]$p
            if ($n -ge 1 -and $n -le $keys.Count) { [void]$picked.Add($keys[$n - 1]) }
        } elseif ($p -match '^(\d+)\s*-\s*(\d+)$') {
            $from = [int]$Matches[1]; $to = [int]$Matches[2]
            if ($from -gt $to) { $tmp = $from; $from = $to; $to = $tmp }
            for ($i = $from; $i -le $to; $i++) {
                if ($i -ge 1 -and $i -le $keys.Count) { [void]$picked.Add($keys[$i - 1]) }
            }
        }
    }
    if ($picked.Count -eq 0) { Write-Warn '未识别任何编号，改用全部组件'; return $keys }
    return $picked.ToArray()
}

# ---------------------------------------------------------------------------
# 快捷方式（全局项）
# ---------------------------------------------------------------------------
function Remove-ShortcutsUnderRoot {
    param([Parameter(Mandatory = $true)][string]$Root)
    $dirs = @((Get-ShortcutDirectory -Kind 'Desktop'), (Get-ShortcutDirectory -Kind 'StartMenu'), [Environment]::GetFolderPath('Startup'))
    $removed = 0
    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($dir in $dirs) {
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            foreach ($lnk in @(Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -File -ErrorAction SilentlyContinue)) {
                try {
                    $sc = $shell.CreateShortcut($lnk.FullName)
                    $target = [string]$sc.TargetPath
                    $lnkArgs = [string]$sc.Arguments
                    if (($target -and $target.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) -or
                        ($lnkArgs -and $lnkArgs -like "*$Root*")) {
                        if (Remove-Shortcut -Path $lnk.FullName) { $removed++ }
                    }
                } catch { }
            }
        }
    } catch {
        Write-Warn "扫描快捷方式失败: $($_.Exception.Message)"
    } finally {
        if ($shell) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { } }
    }
    return $removed
}

function New-GlobalShortcuts {
    param([array]$Catalog, [hashtable]$EnvInfo)
    if ($script:Options -and $script:Options.NoShortcuts) { return }
    if (-not [bool](Get-ConfigValue -Path 'shortcuts.enabled' -Default $true)) { return }
    $wanted = @(Get-ConfigValue -Path 'shortcuts.items' -Default @())
    $root = $script:Ctx.Root
    $targets = New-Object Collections.ArrayList
    if ([bool](Get-ConfigValue -Path 'shortcuts.desktop' -Default $true)) { [void]$targets.Add((Get-ShortcutDirectory -Kind 'Desktop')) }
    if ([bool](Get-ConfigValue -Path 'shortcuts.startMenu' -Default $false)) { [void]$targets.Add((Get-ShortcutDirectory -Kind 'StartMenu')) }
    if ($targets.Count -eq 0) { return }

    $cmdExe = [Environment]::ExpandEnvironmentVariables('%SystemRoot%\System32\cmd.exe')
    $explorer = [Environment]::ExpandEnvironmentVariables('%SystemRoot%\explorer.exe')
    $notepad = [Environment]::ExpandEnvironmentVariables('%SystemRoot%\System32\notepad.exe')
    $envCmd = Join-Path $root 'env.cmd'
    $infoFile = Join-Path $root '数据库连接信息.txt'

    foreach ($dir in $targets) {
        if (($wanted -contains 'devshell') -and (Test-Path -LiteralPath $envCmd)) {
            [void](New-Shortcut -Path (Join-Path $dir 'Java 开发环境终端.lnk') -TargetPath $cmdExe `
                    -Arguments (Get-CmdKArguments -ScriptPath $envCmd) -WorkingDirectory $env:USERPROFILE `
                    -IconLocation $cmdExe -Description '打开已配置好 JAVA_HOME / Maven / PATH 的命令行')
        }
        if ($wanted -contains 'root') {
            [void](New-Shortcut -Path (Join-Path $dir '开发环境目录.lnk') -TargetPath $explorer `
                    -Arguments ('"' + $root + '"') -WorkingDirectory $root -IconLocation $explorer -Description 'JavaDevEnv 安装目录')
        }
        if (($wanted -contains 'dbinfo') -and (Test-Path -LiteralPath $infoFile)) {
            [void](New-Shortcut -Path (Join-Path $dir '数据库连接信息.lnk') -TargetPath $notepad `
                    -Arguments ('"' + $infoFile + '"') -IconLocation $notepad -Description 'PostgreSQL / Redis 连接信息与 Spring Boot 配置')
        }
        # 注意：DSH（桌面端 / 命令行）的快捷方式由组件自己的 Configure-Dsh / Configure-DshCli 生成，
        # 因为命令行版必须带 profile 名启动，不能直接把 dsh.cmd 当作快捷方式目标。
    }
}

function Remove-InstallerComponents {
    # 带安装包的组件（如 DSH 桌面端）自带卸载程序：只删目录会在“添加/删除程序”里留下
    # 指向空目录的失效登记项，所以删目录前先调用它自己的卸载程序。
    param([array]$Catalog, [Parameter(Mandatory = $true)][string]$Root)
    $done = 0
    foreach ($spec in @($Catalog)) {
        if ($spec.Kind -ne 'installer') { continue }
        # 复用的外部安装（不在安装根目录内）不碰
        if (-not $spec.Target -or -not $spec.Target.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not (Test-Path -LiteralPath $spec.Target)) { continue }
        $un = @(Get-ChildItem -LiteralPath $spec.Target -Filter 'Uninstall*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($un.Count -eq 0) {
            Write-Debug2 "未找到自带卸载程序，直接删除目录: $($spec.Target)"
            continue
        }
        if ($script:Options.DryRun) {
            Write-Info "[试运行] 调用自带卸载程序 $($un[0].Name)（$($spec.Target)）"
            continue
        }
        $procName = [string]$spec.Comp.runningProcess
        if (-not [string]::IsNullOrWhiteSpace($procName) -and (Test-RunningProcess -NamePattern $procName)) {
            Write-Warn "$procName 正在运行，跳过自带卸载程序（请先退出它，或手动删除 $($spec.Target)）"
            continue
        }
        Write-Info "调用自带卸载程序: $($un[0].FullName) /S"
        # NSIS 卸载程序会把自己复制到 %TEMP% 再执行，因此这里用输出直通，避免等它继承的管道关闭
        $r = Invoke-Process -FilePath $un[0].FullName -Arguments @('/S') -TimeoutSeconds 600 -InheritConsole -AllowFailure
        if ($r.ExitCode -eq 0) {
            Write-Ok "已调用 $($spec.Name) 的自带卸载程序"
            $done++
        } else {
            Write-Warn "自带卸载程序退出码 $($r.ExitCode)（继续清理残留文件）"
        }
        Start-Sleep -Seconds 3
    }
    return $done
}

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------
function Test-JdkMajorMatches {
    param([string]$HomeDir, [int]$Major)
    $release = Join-Path $HomeDir 'release'
    if (Test-Path -LiteralPath $release) {
        try {
            foreach ($line in @([IO.File]::ReadAllLines($release))) {
                if ($line -match '^\s*JAVA_VERSION\s*=\s*"([^"]+)"') {
                    $ver = $Matches[1]
                    if ($ver -match '^1\.(\d+)') { return ([int]$Matches[1] -eq $Major) }
                    if ($ver -match '^(\d+)') { return ([int]$Matches[1] -eq $Major) }
                }
            }
        } catch { }
    }
    if ($HomeDir -match ('jdk-?1?' + $Major + '(\.|_|-|\\)')) { return $true }
    return $false
}

function Invoke-InstallAction {
    param([hashtable]$Config, [hashtable]$Resolved)

    $catalog = Get-ComponentCatalog -Config $Config -Resolved $Resolved
    if ($script:Options.Components -and $script:Options.Components.Count -gt 0) {
        $catalog = Resolve-SelectedComponents -Config $Config -Catalog $catalog -Components $script:Options.Components -Profile ''
    } elseif (-not [string]::IsNullOrWhiteSpace($Config.profile)) {
        $catalog = Resolve-SelectedComponents -Config $Config -Catalog $catalog -Components @() -Profile ([string]$Config.profile)
    }
    if ($script:Options.Interactive) {
        $picked = Show-InteractiveMenu -Catalog $catalog -Config $Config
        $catalog = Resolve-SelectedComponents -Config $Config -Catalog $catalog -Components $picked -Profile ''
    }
    $script:Catalog = $catalog

    # 显式点名了某个组件，但它被 enabled=false 关掉了 / 名字写错了 → 明确提示，避免“怎么没装”的困惑
    if ($script:Options.Components -and $script:Options.Components.Count -gt 0) {
        foreach ($key in @($script:Options.Components)) {
            if ([string]::IsNullOrWhiteSpace($key) -or $key -eq '*') { continue }
            $matched = @($catalog | Where-Object { $_.Key -eq $key -or $_.Group -eq $key })
            if ($matched.Count -gt 0) { continue }
            $node = Get-ComponentConfig -Name $key
            if ($node -and $node.ContainsKey('enabled') -and -not $node.enabled) {
                Write-Warn "组件 $key 在配置里是 enabled=false（默认未启用），已跳过；要用它请在 config\user.json 里设为 true"
            } elseif ($node -and $node.Count -gt 0) {
                Write-Warn "组件 $key 没有匹配到可安装条目（可能未满足依赖或配置不完整）"
            } else {
                Write-Warn "未知的组件名: $key"
            }
        }
    }

    # 同类工具提醒：dbtool（DBeaver/HeidiSQL）、ssh、apitool、redisgui 内的工具定位相同，
    # 同时装多纯属浪费
    foreach ($groupKey in @('dbtool', 'ssh', 'apitool', 'redisgui')) {
        $members = @($catalog | Where-Object { $_.Group -eq $groupKey })
        if ($members.Count -le 1) { continue }
        $names = ($members | ForEach-Object { $_.Name }) -join '、'
        Write-Warn "本次选中了 $($members.Count) 个同类工具（$names），功能重叠、通常只需其一；"
        Write-Warn "如需只保留一个，可在 config\user.json 里把另一个设为 enabled=false，或用 -Components 指定"
    }

    if (@($catalog).Count -eq 0) {
        Write-Warn '没有需要处理的组件（请检查 config 中的 enabled 或 -Components 参数）'
        return
    }

    # ---------------- 探测已有安装 ----------------
    $policy = [string](Get-ConfigValue -Path 'existingPolicy' -Default 'prefer')
    if ($policy -eq 'prefer' -and -not $script:Options.Force) {
        foreach ($spec in @($catalog)) {
            if (-not $spec.DetectKey) { continue }
            $existing = Find-ExistingComponent -Key $spec.DetectKey
            if (-not $existing) { continue }
            if ($spec.DetectKey -eq 'jdk') {
                $major = 0
                if ($spec.Values.ContainsKey('major')) { $major = [int]$spec.Values['major'] }
                if ($major -gt 0 -and -not (Test-JdkMajorMatches -HomeDir $existing.Home -Major $major)) {
                    Write-Debug2 "已有 JDK（$($existing.Home)）主版本不匹配 $major，将单独安装"
                    continue
                }
            }
            $spec.Adopted = $true
            $spec.Target = $existing.Home
            $spec.ProbePath = $existing.Exe
            $spec.Status = 'adopted'
            $spec.Note = "复用已有安装（$($existing.Source)）"
        }
    }

    # ---------------- 计划 ----------------
    Write-Section '安装计划'
    Write-TableRow -Col1 '组件' -Col2 '版本' -Col3 '动作 / 位置' -Color 'White' -W1 30 -W2 12
    Write-Host ('  ' + ('-' * 66)) -ForegroundColor DarkGray
    foreach ($spec in @($catalog)) {
        $action = '安装'
        if ($spec.Status -eq 'adopted') { $action = '复用已有' }
        elseif (Test-ComponentReady -Spec $spec) { $action = '已存在，跳过' }
        Write-TableRow -Col1 $spec.Name -Col2 $spec.Version -Col3 ("$action  →  $($spec.Target)") `
            -Color (Get-StatusColor -Status $(if ($action -eq '安装') { 'missing' } else { 'skipped' })) -W1 30 -W2 12
    }
    Write-Host ''
    Write-KeyValue -Key '安装根目录' -Value $script:Ctx.Root
    Write-KeyValue -Key '已有组件策略' -Value $policy
    Write-KeyValue -Key '镜像优先' -Value ([string](Test-PreferMirrors))

    if ($script:Options.DryRun) {
        Write-Host ''
        Write-Warn '试运行模式（-DryRun / plan）：以上仅为计划，未对系统做任何改动'
        return
    }

    # ---------------- 环境备份 ----------------
    if ([bool](Get-ConfigValue -Path 'env.backupBeforeChange' -Default $true) -and -not ($script:Options -and $script:Options.NoEnv)) {
        try {
            $backupFile = Join-Path $script:Ctx.Logs ('env-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
            $script:EnvBackupFile = Backup-UserEnvironment -File $backupFile
        } catch {
            Write-Warn "备份环境变量失败: $($_.Exception.Message)"
        }
    }

    # ---------------- 逐个处理 ----------------
    $index = 0
    $total = @($catalog).Count
    foreach ($spec in @($catalog)) {
        $index++
        Write-Section "[$index/$total] $($spec.Name)"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            if ($spec.Status -eq 'adopted') {
                if (-not (Test-ComponentReady -Spec $spec)) { throw "复用已有安装失败：未找到 $($spec.Probe)" }
                Write-Ok "复用已有安装: $($spec.Target)"
            } elseif ((Test-ComponentReady -Spec $spec) -and -not $script:Options.Force) {
                $spec.Status = 'skipped'
                $spec.Note = '已安装，跳过'
                Write-Ok "已存在，跳过: $($spec.Target)"
            } else {
                if ($script:Options.SkipDownload) { throw '指定了 -SkipDownload，但本地不存在该组件' }
                Install-Component -Spec $spec
                $spec.Status = 'installed'
                Write-Ok "安装完成: $($spec.Target)"
            }

            $spec.DetectedVersion = Get-ComponentVersionString -Spec $spec
            if ($spec.DetectedVersion) { Write-Info "版本: $($spec.DetectedVersion)" }

            if ($spec.Configure) {
                $fn = Get-Command -Name $spec.Configure -ErrorAction SilentlyContinue
                if ($fn) {
                    & $spec.Configure -Spec $spec
                } else {
                    Write-Debug2 "未找到配置函数 $($spec.Configure)"
                }
            }

            Set-ComponentEnvironment -Spec $spec
            New-ComponentShortcuts -Spec $spec
        } catch {
            $spec.Status = 'failed'
            $spec.Note = $_.Exception.Message
            Write-Err "$($spec.Name) 处理失败: $($_.Exception.Message)"
            if ([bool](Get-ConfigValue -Path 'stopOnError' -Default $false)) {
                $sw.Stop()
                $spec.Duration = [int]$sw.Elapsed.TotalSeconds
                [void]$script:Results.Add($spec)
                throw
            }
        }
        $sw.Stop()
        $spec.Duration = [int]$sw.Elapsed.TotalSeconds
        [void]$script:Results.Add($spec)
    }

    # ---------------- 全局收尾 ----------------
    try {
        # MAVEN_OPTS
        $mavenOpts = [string](Get-ConfigValue -Path 'env.mavenOpts' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($mavenOpts) -and -not ($script:Options -and $script:Options.NoEnv)) {
            $existing = Get-UserEnvRaw -Name 'MAVEN_OPTS'
            if (-not $existing.Exists) {
                Set-UserEnvRaw -Name 'MAVEN_OPTS' -Value $mavenOpts
                Write-Info "设置用户环境变量 MAVEN_OPTS = $mavenOpts"
            } elseif ($existing.Value -notlike "*$mavenOpts*") {
                Write-Info "MAVEN_OPTS 已存在（$($existing.Value)），未修改"
            }
        }
        $envInfo = Write-EnvironmentScripts -Catalog @($catalog)
        New-DbInfoFile -Catalog @($catalog) | Out-Null
        New-GlobalShortcuts -Catalog @($catalog) -EnvInfo $envInfo
        Register-Autostart -Catalog @($catalog) | Out-Null
        Send-EnvironmentChanged
    } catch {
        Write-Warn "收尾步骤出现问题: $($_.Exception.Message)"
    }

    Write-InstallSummary
}

function Write-InstallSummary {
    $results = @($script:Results)
    Write-Section '安装结果'
    Write-TableRow -Col1 '组件' -Col2 '状态' -Col3 '位置 / 说明' -Color 'White' -W1 30 -W2 12
    Write-Host ('  ' + ('-' * 66)) -ForegroundColor DarkGray
    $ok = 0; $fail = 0
    foreach ($spec in $results) {
        $status = Get-StatusText -Status $spec.Status
        $detail = $spec.Target
        if ($spec.Status -eq 'failed') { $detail = $spec.Note; $fail++ } else { $ok++ }
        Write-TableRow -Col1 $spec.Name -Col2 $status -Col3 $detail -Color (Get-StatusColor -Status $spec.Status) -W1 30 -W2 12
    }
    Write-Host ''
    Write-Host ("  成功/跳过: $ok    失败: $fail") -ForegroundColor $(if ($fail -gt 0) { 'Yellow' } else { 'Green' })
    if ($script:Warnings.Count -gt 0) {
        Write-Host ''
        Write-Host ("  警告 $($script:Warnings.Count) 条：") -ForegroundColor Yellow
        foreach ($w in @($script:Warnings | Select-Object -Unique)) { Write-Host "    - $w" -ForegroundColor DarkYellow }
    }

    # 报告文件
    try {
        $lines = New-Object Collections.ArrayList
        [void]$lines.Add('# JavaDevEnv 安装报告')
        [void]$lines.Add('')
        [void]$lines.Add('- 时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        [void]$lines.Add("- 安装目录: $($script:Ctx.Root)")
        [void]$lines.Add("- 日志文件: $($script:LogFile)")
        [void]$lines.Add("- 环境备份: $($script:EnvBackupFile)")
        [void]$lines.Add('')
        [void]$lines.Add('| 组件 | 状态 | 版本 | 位置 |')
        [void]$lines.Add('| --- | --- | --- | --- |')
        foreach ($spec in $results) {
            [void]$lines.Add("| $($spec.Name) | $(Get-StatusText -Status $spec.Status) | $($spec.Version) | $($spec.Target) |")
        }
        [void]$lines.Add('')
        if ($script:Warnings.Count -gt 0) {
            [void]$lines.Add('## 警告')
            foreach ($w in @($script:Warnings | Select-Object -Unique)) { [void]$lines.Add("- $w") }
            [void]$lines.Add('')
        }
        $report = Join-Path $script:Ctx.Logs ('install-report-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.md')
        Write-TextFileBom -Path $report -Lines $lines.ToArray()
        Write-Info "安装报告: $report"
    } catch {
        Write-Debug2 "写报告失败: $($_.Exception.Message)"
    }

    Write-Section '下一步'
    Write-Host '  1. 环境变量已写入用户级配置，请【新开一个终端】后执行 java -version / mvn -v 验证' -ForegroundColor Gray
    Write-Host ("  2. 需要临时生效可执行: $($script:Ctx.Root)\env.cmd") -ForegroundColor Gray
    Write-Host '  3. 桌面快捷方式可一键启动 PostgreSQL / Redis，连接信息见「数据库连接信息」' -ForegroundColor Gray
    Write-Host '  4. 环境自检: 运行 doctor.cmd（或 install.cmd doctor）' -ForegroundColor Gray
    if ($script:EnvBackupFile) {
        Write-Host ("  5. 若需回滚环境变量: install.cmd restore -BackupFile `"$($script:EnvBackupFile)`"") -ForegroundColor DarkGray
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# 开机自启
# ---------------------------------------------------------------------------
function Invoke-AutostartAction {
    # 单独应用开机自启配置：在 config\user.json 里调整 components.*.autostart 后，
    # 运行 install.cmd -Action autostart 即可生效，无需重跑完整安装。
    param([hashtable]$Config, [hashtable]$Resolved)
    Write-Section '开机自启配置 (autostart)'
    $catalog = Get-ComponentCatalog -Config $Config -Resolved $Resolved
    $count = Register-Autostart -Catalog @($catalog)
    if ($count -eq 0) { Write-Info '没有设置新的自启项（对应开关未打开，或启动目标尚未安装）' }
    Write-Host ('  「启动」文件夹: ' + [Environment]::GetFolderPath('Startup')) -ForegroundColor DarkGray
    Write-Host '  说明: PostgreSQL / Redis 以隐藏窗口方式拉起（Redis 常驻通知区域托盘，右键可重启/停止）；DSH 桌面端直接指向其主程序。' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 状态
# ---------------------------------------------------------------------------
function Invoke-StatusAction {
    param([hashtable]$Config, [hashtable]$Resolved)
    $catalog = Get-ComponentCatalog -Config $Config -Resolved $Resolved
    Write-Section 'Java 开发环境状态'
    Write-KeyValue -Key '安装根目录' -Value $script:Ctx.Root
    Write-KeyValue -Key '配置文件' -Value $script:Ctx.ConfigFile
    $userCfgPath = [string]$script:Ctx.UserConfigFile
    $userCfgText = '(未使用)'
    if (-not [string]::IsNullOrWhiteSpace($userCfgPath) -and (Test-Path -LiteralPath $userCfgPath)) { $userCfgText = $userCfgPath }
    Write-KeyValue -Key '用户配置文件' -Value $userCfgText
    Write-Host ''
    Write-TableRow -Col1 '组件' -Col2 '状态' -Col3 '版本 / 位置' -Color 'White' -W1 30 -W2 12
    Write-Host ('  ' + ('-' * 66)) -ForegroundColor DarkGray

    foreach ($spec in @($catalog)) {
        $installed = Test-ComponentReady -Spec $spec
        $marker = $null
        if ($installed) { $marker = Get-ComponentMarker -Target $spec.Target }
        $status = 'missing'
        $detail = $spec.Target
        if ($installed) {
            $status = 'installed'
            if ($marker -and $marker.source -eq 'adopted') { $status = 'adopted' }
            $detail = "$($spec.Version)   $($spec.Target)"
        } else {
            $existing = $null
            if ($spec.DetectKey) { $existing = Find-ExistingComponent -Key $spec.DetectKey }
            if ($existing) {
                $status = 'adopted'
                $detail = "$($spec.Version)   $($existing.Home)  [$($existing.Source)]"
            }
        }
        Write-TableRow -Col1 $spec.Name -Col2 (Get-StatusText -Status $status) -Col3 $detail -Color (Get-StatusColor -Status $status) -W1 30 -W2 12
    }

    Write-Host ''
    Write-Host '  用户环境变量:' -ForegroundColor White
    foreach ($name in @('JAVA_HOME', 'MAVEN_HOME', 'MAVEN_OPTS', 'NPM_CONFIG_PREFIX')) {
        $v = Get-UserEnvRaw -Name $name
        $text = '(未设置)'
        if ($v.Exists) { $text = $v.Value }
        Write-KeyValue -Key "  $name" -Value $text
    }
    $pathRaw = Get-UserEnvRaw -Name 'Path'
    $hits = @()
    foreach ($spec in @($catalog)) {
        foreach ($rel in @($spec.PathEntries)) {
            $dir = $spec.Target
            if ($rel -and $rel -ne '.') { $dir = Join-Path $spec.Target $rel }
            foreach ($item in @($pathRaw.Value -split ';')) {
                if ($item.Trim().TrimEnd('\') -ieq $dir.TrimEnd('\')) { $hits += $dir }
            }
        }
    }
    Write-Host ''
    Write-Host ("  用户 PATH 中已登记的本环境目录: $($hits.Count) 个") -ForegroundColor White
    foreach ($h in $hits) { Write-Host "    - $h" -ForegroundColor DarkGray }
    Write-Host ("  用户 PATH 总长度: $($pathRaw.Value.Length) 字符") -ForegroundColor DarkGray
    Write-Host ''

    $problems = @($catalog | Where-Object { -not (Test-ComponentReady -Spec $_) })
    if ($problems.Count -eq 0) {
        Write-Ok '所有已启用组件均已就绪'
    } else {
        Write-Warn "$($problems.Count) 个组件尚未安装：$(($problems | ForEach-Object { $_.Key }) -join ', ')"
        Write-Host '  执行 install.cmd 即可安装缺失组件。' -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# 自检
# ---------------------------------------------------------------------------
function Invoke-DoctorAction {
    param([hashtable]$Config, [hashtable]$Resolved)
    Write-Section '环境自检 (doctor)'

    $script:DoctorRows = New-Object Collections.ArrayList
    function Add-Check {
        param([string]$Name, [string]$State, [string]$Detail)
        $color = 'Gray'
        switch ($State) {
            '通过' { $color = 'Green' }
            '警告' { $color = 'Yellow' }
            '失败' { $color = 'Red' }
            '跳过' { $color = 'DarkGray' }
        }
        [void]$script:DoctorRows.Add(@{ Name = $Name; Level = $State; Detail = $Detail })
        Write-TableRow -Col1 $Name -Col2 $State -Col3 $Detail -Color $color -W1 34 -W2 8
    }

    # ---- 系统 ----
    Add-Check '操作系统' '通过' ((Get-CimInstance Win32_OperatingSystem).Caption)
    $isAdmin = Test-IsAdmin
    Add-Check '管理员权限' $(if ($isAdmin) { '通过' } else { '警告' }) $(if ($isAdmin) { '当前为管理员' } else { '非管理员（本工具不需要管理员权限）' })
    Add-Check 'PowerShell 版本' '通过' $PSVersionTable.PSVersion.ToString()
    Add-Check '系统语言' '通过' (Get-Culture).Name

    $longPath = $null
    try {
        $longPath = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -ErrorAction Stop).LongPathsEnabled
    } catch { }
    Add-Check '长路径支持' $(if ($longPath -eq 1) { '通过' } else { '警告' }) $(if ($longPath -eq 1) { 'LongPathsEnabled=1' } else { 'LongPathsEnabled 未开启，深层目录可能报错' })

    $free = Get-FreeSpaceGB -Path $script:Ctx.Root
    Add-Check '可用磁盘空间' $(if ($free -lt 5) { '失败' } elseif ($free -lt 20) { '警告' } else { '通过' }) "$free GB ($(Split-Path -Qualifier $script:Ctx.Root))"

    $execPolicy = Get-ExecutionPolicy
    Add-Check '脚本执行策略' '通过' ([string]$execPolicy)

    # ---- 各组件 ----
    $catalog = Get-ComponentCatalog -Config $Config -Resolved $Resolved
    Write-Host ''
    foreach ($spec in @($catalog)) {
        if ($spec.Status -eq 'failed') { continue }
        if (-not (Test-ComponentReady -Spec $spec)) {
            if ($spec.DetectKey) {
                $existing = Find-ExistingComponent -Key $spec.DetectKey
                if ($existing) {
                    Add-Check $spec.Name '警告' "未由本工具安装，但检测到: $($existing.Home)"
                    continue
                }
            }
            Add-Check $spec.Name '失败' "未安装（$($spec.Target)）"
            continue
        }
        if ([string]::IsNullOrWhiteSpace($spec.Probe)) {
            Add-Check $spec.Name '通过' $spec.Target
            continue
        }
        $version = Get-ComponentVersionString -Spec $spec
        if ($version) {
            Add-Check $spec.Name '通过' $version
        } else {
            Add-Check $spec.Name '通过' $spec.ProbePath
        }
    }

    Write-Host ''
    # ---- PostgreSQL ----
    $pgSpec = @($catalog | Where-Object { $_.Key -eq 'postgres' })[0]
    if ($pgSpec -and (Test-Path -LiteralPath $pgSpec.Target)) {
        $running = Test-PostgresRunning -Spec $pgSpec
        $pgHint = '未运行（双击桌面「PostgreSQL-启动」）'
        if (-not $running -and (Test-IsAdmin)) {
            $pgHint = '未运行：当前是管理员终端，PostgreSQL 不允许以管理员身份启动，请用桌面快捷方式（普通权限）启动'
        }
        Add-Check 'PostgreSQL 服务' $(if ($running) { '通过' } else { '警告' }) $(if ($running) { '正在运行' } else { $pgHint })
        if ($running) {
            $psql = Join-Path $pgSpec.Target 'bin\psql.exe'
            $port = Get-EffectivePort -Spec $pgSpec -Default ([int](Get-ObjectProperty -Object $pgSpec.Comp -Name 'port' -Default 5432))
            $user = [string](Get-ObjectProperty -Object $pgSpec.Comp -Name 'superuser' -Default 'postgres')
            $password = [string](Get-ObjectProperty -Object $pgSpec.Comp -Name 'password' -Default 'postgres')
            $oldPw = $env:PGPASSWORD
            $env:PGPASSWORD = $password
            try {
                $r = Invoke-Process -FilePath $psql -Arguments @('-h', '127.0.0.1', '-p', "$port", '-U', $user, '-tAc', 'SELECT version()') -TimeoutSeconds 45 -AllowFailure
                $out = ($r.StdOut + $r.StdErr).Trim()
                if ($out -match 'PostgreSQL') {
                    $lastLine = @($out -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                    $detail = $lastLine[$lastLine.Count - 1]
                    if ($detail.Length -gt 60) { $detail = $detail.Substring(0, 60) }
                    Add-Check 'PostgreSQL 连接' '通过' $detail
                } else {
                    Add-Check 'PostgreSQL 连接' '失败' $out
                }
            } finally {
                if ($null -eq $oldPw) { Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD = $oldPw }
            }
        }
    }
    # ---- Redis ----
    $redisSpec = @($catalog | Where-Object { $_.Key -eq 'redis' })[0]
    if ($redisSpec -and (Test-Path -LiteralPath $redisSpec.Target)) {
        $running = Test-RedisRunning -Spec $redisSpec
        Add-Check 'Redis 服务' $(if ($running) { '通过' } else { '警告' }) $(if ($running) { '正在运行' } else { '未运行（双击桌面「Redis-启动」）' })
    }

    Write-Host ''
    # ---- 开机自启（登录时由「启动」文件夹拉起） ----
    $startupDir = [Environment]::GetFolderPath('Startup')
    foreach ($pair in @(
            @('JavaDevEnv-PostgreSQL.lnk', 'PostgreSQL 自启'),
            @('JavaDevEnv-Redis.lnk', 'Redis 自启'),
            @('JavaDevEnv-DSH.lnk', 'DSH 桌面端自启'))) {
        $lnkPath = Join-Path $startupDir $pair[0]
        if (Test-Path -LiteralPath $lnkPath) {
            Add-Check $pair[1] '通过' '已设置（登录后自动拉起）'
        } else {
            Add-Check $pair[1] '跳过' '未设置（components.*.autostart=false 或未安装）'
        }
    }

    Write-Host ''
    # ---- 端口 ----
    foreach ($spec in @($catalog | Where-Object { $_.Key -eq 'postgres' -or $_.Key -eq 'redis' })) {
        $port = 0
        if ($spec.Key -eq 'postgres') { $port = Get-EffectivePort -Spec $spec -Default ([int](Get-ObjectProperty -Object $spec.Comp -Name 'port' -Default 5432)) }
        if ($spec.Key -eq 'redis') { $port = Get-EffectivePort -Spec $spec -Default ([int](Get-ObjectProperty -Object $spec.Comp -Name 'port' -Default 6379)) }
        if ($port -gt 0) {
            $inUse = -not (Test-TcpPortFree -Port $port)
            Add-Check "端口 $port" $(if ($inUse) { '通过' } else { '警告' }) $(if ($inUse) { '已被监听（服务在运行）' } else { '未被监听' })
        }
    }

    # ---- 汇总 ----
    $rows = @($script:DoctorRows)
    $passCount = @($rows | Where-Object { $_.Level -eq '通过' }).Count
    $warnCount = @($rows | Where-Object { $_.Level -eq '警告' }).Count
    $failCount = @($rows | Where-Object { $_.Level -eq '失败' }).Count
    Write-Host ''
    Write-Host ("  自检完成：通过 $passCount，警告 $warnCount，失败 $failCount") -ForegroundColor $(if ($failCount -gt 0) { 'Red' } elseif ($warnCount -gt 0) { 'Yellow' } else { 'Green' })
    Write-Host '  提示：警告项通常不影响使用，失败项请按提示处理后重试。' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------
function Invoke-UninstallAction {
    param([hashtable]$Config, [hashtable]$Resolved, [string]$BackupFile)
    Write-Section '卸载 / 回滚 JavaDevEnv'
    $root = $script:Ctx.Root
    $uninstallCfg = Get-ConfigValue -Path 'uninstall' -Default @{}
    $removeShortcuts = [bool](Get-ObjectProperty -Object $uninstallCfg -Name 'removeShortcuts' -Default $true)
    $removeEnv = [bool](Get-ObjectProperty -Object $uninstallCfg -Name 'removeEnvVars' -Default $true)
    $removeFiles = [bool](Get-ObjectProperty -Object $uninstallCfg -Name 'removeFiles' -Default $true)
    $keepData = [bool](Get-ObjectProperty -Object $uninstallCfg -Name 'keepData' -Default $true)

    if ($script:Options.DryRun) { Write-Warn '试运行模式：以下操作不会真正执行' }

    if ($removeShortcuts) {
        $n = Remove-ShortcutsUnderRoot -Root $root
        Write-Info "已清理快捷方式 $n 个"
        # 开机自启项不看配置开关，卸载时一律移除
        $autoRemoved = Unregister-Autostart
        if ($autoRemoved -gt 0) { Write-Info "已清理开机自启项 $autoRemoved 个" }
    }

    if ($removeEnv) {
        $catalog = Get-ComponentCatalog -Config $Config -Resolved $Resolved
        foreach ($spec in @($catalog)) {
            foreach ($rel in @($spec.PathEntries)) {
                $dir = $spec.Target
                if ($rel -and $rel -ne '.') { $dir = Join-Path $spec.Target $rel }
                # 只有位于安装根目录内的才移除
                if ($dir.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                    [void](Remove-UserPathEntry -Entry $dir)
                }
            }
        }
        foreach ($name in @('JAVA_HOME', 'MAVEN_HOME', 'M2_HOME', 'MAVEN_OPTS', 'JAVA_HOME_8', 'JAVA_HOME_11', 'JAVA_HOME_17', 'JAVA_HOME_21', 'JAVA_HOME_25')) {
            $v = Get-UserEnvRaw -Name $name
            if (-not $v.Exists) { continue }
            if ($v.Value.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or ($name -eq 'MAVEN_OPTS' -and $v.Value -like '*file.encoding=UTF-8*')) {
                $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
                if ($key) {
                    try { $key.DeleteValue($name, $false); Write-Info "已删除用户环境变量 $name" } catch { }
                    $key.Close()
                }
            } else {
                Write-Info "$name 指向本环境之外（$($v.Value)），保留"
            }
        }
        Send-EnvironmentChanged
    }

    if ($removeFiles -and (Test-Path -LiteralPath $root)) {
        # 先结束 Redis 托盘管理器并优雅停止 Redis，避免进程占用文件导致目录删不掉
        Stop-RedisTrayProcess
        try {
            $stopCatalog = Get-ComponentCatalog -Config $Config -Resolved $Resolved
            foreach ($stopSpec in @($stopCatalog | Where-Object { $_.Key -eq 'redis' })) {
                if (Test-RedisRunning -Spec $stopSpec) { [void](Stop-RedisServer -Spec $stopSpec) }
            }
        } catch { }
        # 先让带安装包的组件（DSH 桌面端）走它们自己的卸载程序，避免留下失效的卸载登记项
        try {
            $instCatalog = Get-ComponentCatalog -Config $Config -Resolved $Resolved
            $n = Remove-InstallerComponents -Catalog @($instCatalog) -Root $root
            if ($n -gt 0) { Write-Info "已卸载 $n 个自带安装程序的组件" }
        } catch {
            Write-Warn "调用自带卸载程序时出错: $($_.Exception.Message)"
        }
        $preserve = @()
        if ($keepData) { $preserve += (Join-Path $root 'data') }
        Write-Info "删除安装目录 $root$(if ($keepData) { '（保留 data 数据目录）' })"
        if (-not $script:Options.DryRun) {
            $preservePaths = @()
            foreach ($p in $preserve) {
                if (Test-Path -LiteralPath $p) {
                    $tmpPreserve = Join-Path $env:TEMP ('javadevenv-keep-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
                    Move-Item -LiteralPath $p -Destination $tmpPreserve -Force
                    $preservePaths += @{ From = $tmpPreserve; To = $p }
                }
            }
            Remove-PathRobust -Path $root
            foreach ($item in $preservePaths) {
                New-Item -ItemType Directory -Path $root -Force | Out-Null
                Move-Item -LiteralPath $item.From -Destination $item.To -Force
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($BackupFile)) {
        Write-Info "从备份恢复环境变量: $BackupFile"
        [void](Restore-UserEnvironment -File $BackupFile)
    }
    Write-Ok '卸载流程结束'
    Write-Host '  提示：如需完全清理，请检查桌面/开始菜单快捷方式与用户环境变量。' -ForegroundColor DarkGray
}
