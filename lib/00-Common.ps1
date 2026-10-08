# ===========================================================================
#  00-Common.ps1  —  公共基础设施
#  日志 / 配置 / 下载 / 解压 / 用户环境变量 / 快捷方式 / 进程调用
#  本文件由 Setup-JavaDevEnv.ps1 点源加载，仅使用 Windows PowerShell 5.1 兼容语法。
# ===========================================================================

$script:ToolName    = 'JavaDevEnv'
$script:ToolVersion = '1.1.2'
$script:UserAgent   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) JavaDevEnv/1.1'
$script:LogFile     = ''
$script:LogLevel    = 'Info'
$script:LogLevels   = @{ 'Debug' = 10; 'Info' = 20; 'Warn' = 30; 'Error' = 40; 'None' = 99 }
$script:Warnings    = New-Object Collections.ArrayList
$script:Errors      = New-Object Collections.ArrayList
$script:Results     = New-Object Collections.ArrayList

# ---------------------------------------------------------------------------
# 基本环境
# ---------------------------------------------------------------------------
function Initialize-BaseEnvironment {
    # PowerShell 5.1 默认可能只启用 TLS1.0，很多镜像站会直接拒绝
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {
        Write-Log -Level Debug -Message "设置 TLS1.2 失败: $($_.Exception.Message)"
    }
    try {
        [Net.ServicePointManager]::DefaultConnectionLimit = 8
        [Net.ServicePointManager]::Expect100Continue = $false
    } catch { }
    # 保证进度条与数字格式稳定
    try { [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('zh-CN') } catch { }
}

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-FreeSpaceGB {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $root = [IO.Path]::GetPathRoot($full)
        $device = $root.TrimEnd('\')
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$device'" -ErrorAction Stop
        if ($disk -and $disk.FreeSpace) { return [math]::Round($disk.FreeSpace / 1GB, 1) }
    } catch { }
    return -1
}

function Format-FileSize {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
function Initialize-Logging {
    param([string]$Directory, [string]$Level = 'Info')
    $script:LogLevel = $Level
    if ($Directory) {
        if ($script:Options -and $script:Options.DryRun) {
            # 试运行/plan 模式不落盘，避免产生任何副作用
            $script:LogFile = ''
            return
        }
        try {
            if (-not (Test-Path -LiteralPath $Directory)) {
                # 安装目录还不存在（例如只做状态检查）时仅输出到控制台，不产生任何副作用
                $script:LogFile = ''
                return
            }
            $script:LogFile = Join-Path $Directory ('setup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
        } catch {
            $script:LogFile = ''
        }
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Level = 'Info',
        [switch]$NoConsole
    )
    $levels = $script:LogLevels
    $threshold = 20
    if ($levels.ContainsKey($script:LogLevel)) { $threshold = $levels[$script:LogLevel] }
    $current = 20
    if ($levels.ContainsKey($Level)) { $current = $levels[$Level] }
    if ($current -lt $threshold) { return }

    $prefix = '[信息]'
    $color = 'Gray'
    switch ($Level) {
        'Debug' { $prefix = '[调试]'; $color = 'DarkGray' }
        'Info'  { $prefix = '[信息]'; $color = 'Gray' }
        'Ok'    { $prefix = '[完成]'; $color = 'Green' }
        'Warn'  { $prefix = '[警告]'; $color = 'Yellow' }
        'Error' { $prefix = '[错误]'; $color = 'Red' }
        'Step'  { $prefix = '==>';    $color = 'Cyan' }
    }

    if (-not $NoConsole) {
        try { Write-Host "$prefix $Message" -ForegroundColor $color } catch { Write-Host "$prefix $Message" }
    }

    if ($script:LogFile) {
        $line = ('{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
        try { [IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, (New-Object Text.UTF8Encoding $false)) } catch { }
    }

    if ($Level -eq 'Warn') { [void]$script:Warnings.Add($Message) }
    if ($Level -eq 'Error') { [void]$script:Errors.Add($Message) }
}

function Write-Info  { param([string]$Message) Write-Log -Message $Message -Level 'Info' }
function Write-Ok    { param([string]$Message) Write-Log -Message $Message -Level 'Ok' }
function Write-Warn  { param([string]$Message) Write-Log -Message $Message -Level 'Warn' }
function Write-Err   { param([string]$Message) Write-Log -Message $Message -Level 'Error' }
function Write-Debug2 { param([string]$Message) Write-Log -Message $Message -Level 'Debug' }

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Title)
    Write-Host ''
    Write-Host ('-' * 70) -ForegroundColor DarkCyan
    Write-Host ("  $Title") -ForegroundColor Cyan
    Write-Host ('-' * 70) -ForegroundColor DarkCyan
    Write-Log -Message ("==== $Title ====") -Level 'Info' -NoConsole
}

function Write-KeyValue {
    param([string]$Key, [string]$Value, [string]$Color = 'Gray')
    Write-Host ('  {0,-22} {1}' -f $Key, $Value) -ForegroundColor $Color
}

# ---------------------------------------------------------------------------
# 配置读取 / 合并
# ---------------------------------------------------------------------------
function ConvertTo-DeepHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [hashtable]) {
        $out = @{}
        foreach ($k in @($InputObject.Keys)) { $out[$k] = ConvertTo-DeepHashtable $InputObject[$k] }
        return $out
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $out = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $out[$p.Name] = ConvertTo-DeepHashtable $p.Value }
        return $out
    }
    if (($InputObject -is [System.Collections.IEnumerable]) -and ($InputObject -isnot [string])) {
        $list = New-Object Collections.ArrayList
        foreach ($item in $InputObject) { [void]$list.Add((ConvertTo-DeepHashtable $item)) }
        return , $list.ToArray()
    }
    return $InputObject
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @{} }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($text)) { return @{} }
    $obj = $text | ConvertFrom-Json
    $hash = ConvertTo-DeepHashtable $obj
    if ($null -eq $hash) { return @{} }
    return $hash
}

function Merge-DeepHashtable {
    param([hashtable]$Base, [hashtable]$Override)
    if (-not $Override) { return $Base }
    foreach ($k in @($Override.Keys)) {
        if ($k -like '_*') { continue }                     # 以 _ 开头视为注释
        $v = $Override[$k]
        if ($null -eq $v) { continue }
        if (($v -is [string]) -and ($v -eq '')) { continue }   # 空字符串视为未设置
        if (($v -is [hashtable]) -and $Base.ContainsKey($k) -and ($Base[$k] -is [hashtable])) {
            $Base[$k] = Merge-DeepHashtable -Base $Base[$k] -Override $v
        } else {
            $Base[$k] = $v
        }
    }
    return $Base
}

function Resolve-ConfigTokens {
    param($Node, [hashtable]$Tokens)
    if ($Node -is [hashtable]) {
        foreach ($k in @($Node.Keys)) { $Node[$k] = Resolve-ConfigTokens -Node $Node[$k] -Tokens $Tokens }
        return $Node
    }
    if (($Node -is [System.Collections.IEnumerable]) -and ($Node -isnot [string])) {
        $arr = @($Node)
        for ($i = 0; $i -lt $arr.Count; $i++) { $arr[$i] = Resolve-ConfigTokens -Node $arr[$i] -Tokens $Tokens }
        return , $arr
    }
    if ($Node -is [string]) {
        $s = $Node
        foreach ($k in @($Tokens.Keys)) { $s = $s.Replace('{' + $k + '}', [string]$Tokens[$k]) }
        return $s
    }
    return $Node
}

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        $Default = $null,
        [hashtable]$Root = $null
    )
    if (-not $Root) { $Root = $script:Config }
    if (-not $Root) { return $Default }
    $node = $Root
    foreach ($part in ($Path -split '\.')) {
        if ($node -is [hashtable]) {
            if ($node.ContainsKey($part)) { $node = $node[$part] } else { return $Default }
        } else {
            return $Default
        }
        if ($null -eq $node) { return $Default }
    }
    return $node
}

function Get-ComponentConfig {
    param([Parameter(Mandatory = $true)][string]$Name)
    $node = Get-ConfigValue -Path "components.$Name" -Default @{}
    if ($node -isnot [hashtable]) { return @{} }
    return $node
}

# ---------------------------------------------------------------------------
# 安装根目录
# ---------------------------------------------------------------------------
function Resolve-InstallRoot {
    param([hashtable]$Config)
    $candidates = New-Object Collections.ArrayList
    $primary = [string]$Config.installRoot
    if (-not [string]::IsNullOrWhiteSpace($primary)) {
        [void]$candidates.Add([Environment]::ExpandEnvironmentVariables($primary))
    }
    foreach ($c in @($Config.installRootFallback)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$c)) {
            [void]$candidates.Add([Environment]::ExpandEnvironmentVariables([string]$c))
        }
    }
    foreach ($c in $candidates) {
        try {
            $full = [IO.Path]::GetFullPath($c)
            $drive = [IO.Path]::GetPathRoot($full)
            if ([string]::IsNullOrWhiteSpace($drive)) { continue }
            if (-not (Test-Path -LiteralPath $drive)) { continue }
            $free = Get-FreeSpaceGB -Path $drive
            if ($free -ge 0 -and $free -lt 20) {
                Write-Warn "磁盘 $drive 剩余空间不足 20GB（当前 $free GB），跳过 $full"
                continue
            }
            return $full
        } catch { }
    }
    return (Join-Path $env:USERPROFILE 'JavaDevEnv')
}

function New-DirectoryFor {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$Quiet)
    if (Test-Path -LiteralPath $Path) { return $false }
    if ($script:Options -and $script:Options.DryRun) {
        if (-not $Quiet) { Write-Info "[试运行] 创建目录 $Path" }
        return $true
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    if (-not $Quiet) { Write-Debug2 "创建目录 $Path" }
    return $true
}

function Remove-PathRobust {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    for ($i = 0; $i -lt 3; $i++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        } catch {
            try {
                Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
                    ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
            } catch { }
            Start-Sleep -Milliseconds 400
        }
    }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 下载
# ---------------------------------------------------------------------------
function Read-CapturedText {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return '' }
    try {
        $bytes = [IO.File]::ReadAllBytes($File)
        if ($bytes.Length -eq 0) { return '' }
        $enc = [Console]::OutputEncoding
        if ($null -eq $enc) { $enc = [Text.Encoding]::Default }
        try {
            if ($enc.CodePage -eq 65001) { $enc = New-Object Text.UTF8Encoding $false }
        } catch { }
        try { return $enc.GetString($bytes) } catch { return [Text.Encoding]::UTF8.GetString($bytes) }
    } catch {
        return ''
    }
}

function ConvertTo-ProcessArgument {
    param([string]$Argument)
    if ($null -eq $Argument) { return '""' }
    if ($Argument -eq '') { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }
    $escaped = $Argument -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Invoke-Process {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 120,
        [string]$WorkingDirectory = '',
        [switch]$AllowFailure,
        # 输出直通当前控制台（不捕获）。用于会派生“常驻子进程”的命令，
        # 例如 pg_ctl start 会拉起 postgres.exe 并继承输出管道——捕获会导致永久阻塞。
        [switch]$InheritConsole,
        # 经 Shell（ShellExecuteEx，与用户双击同一路径）启动而非直接 CreateProcess。
        # 用途：部分安全软件的行为防御只拦“控制台进程静默拉起安装器”，不拦用户双击；
        # 直启被拒（文件本身完好）时换 Shell 方式重试。注意该模式下不能重定向输出。
        [switch]$UseShellExecute
    )
    # 说明：这里直接使用 .NET 的 Process 而不是 Start-Process。
    # 实测 PowerShell 5.1 的 Start-Process -PassThru 在部分环境下取不到 ExitCode（返回空），
    # 而 [Diagnostics.Process]::Start 的 ExitCode 稳定可靠。
    $argLine = (@($Arguments) | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) }) -join ' '

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    if (-not [string]::IsNullOrWhiteSpace($argLine)) { $psi.Arguments = $argLine }
    $psi.UseShellExecute = [bool]$UseShellExecute
    $redirect = (-not $InheritConsole) -and (-not $UseShellExecute)
    $psi.RedirectStandardOutput = $redirect
    $psi.RedirectStandardError = $redirect
    $psi.CreateNoWindow = $true
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory }
    if ($redirect) {
        try {
            $encoding = [Console]::OutputEncoding
            if ($encoding) {
                $psi.StandardOutputEncoding = $encoding
                $psi.StandardErrorEncoding = $encoding
            }
        } catch { }
    }

    $proc = $null
    try {
        $proc = [Diagnostics.Process]::Start($psi)
    } catch {
        if (-not $AllowFailure) { throw }
        return @{ ExitCode = -1; StdOut = ''; StdErr = $_.Exception.Message; TimedOut = $false; Failed = $true; PipeHeld = $false }
    }

    $stdout = ''
    $stderr = ''
    $exitCode = -1
    $timedOut = $false
    $pipeHeld = $false
    try {
        $outTask = $null
        $errTask = $null
        if ($redirect) {
            # 异步读取，避免子进程写满 stderr 缓冲区导致死锁
            $outTask = $proc.StandardOutput.ReadToEndAsync()
            $errTask = $proc.StandardError.ReadToEndAsync()
        }
        $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            $timedOut = $true
            try { $proc.Kill() } catch { }
            [void]$proc.WaitForExit(5000)
        }
        try { $exitCode = $proc.ExitCode } catch { $exitCode = -1 }

        if ($redirect) {
            # 有界读取：如果命令派生了常驻子进程并继承了输出管道，管道永不关闭，
            # ReadToEnd 会一直阻塞（表现为脚本“卡死”）。这里限时读取后放弃，保证流程继续。
            if ($outTask.Wait(10000)) {
                try { $stdout = $outTask.Result } catch { }
            } else {
                $pipeHeld = $true
                Write-Debug2 "标准输出读取超时（可能有常驻子进程占用输出管道，已跳过）: $FilePath"
            }
            if ($errTask.Wait(3000)) {
                try { $stderr = $errTask.Result } catch { }
            } else {
                $pipeHeld = $true
                Write-Debug2 "标准错误读取超时（已跳过）: $FilePath"
            }
        }
    } finally {
        try { $proc.Dispose() } catch { }
    }
    return @{ ExitCode = $exitCode; StdOut = $stdout; StdErr = $stderr; TimedOut = $timedOut; Failed = $false; PipeHeld = $pipeHeld }
}

function Invoke-StreamDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [long]$ExpectedSize = 0,
        [string]$Label = ''
    )
    $part = "$OutFile.part"
    $label = $Label
    if ([string]::IsNullOrWhiteSpace($label)) { $label = Split-Path -Leaf $OutFile }
    $activity = "下载 $label"

    $attempts = 2   # 第一次可续传；若服务端拒绝 Range 则重来一次
    for ($attempt = 0; $attempt -lt $attempts; $attempt++) {
        $existing = 0
        if (Test-Path -LiteralPath $part) { $existing = (Get-Item -LiteralPath $part).Length }

        $req = [Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.UserAgent = $script:UserAgent
        $req.AllowAutoRedirect = $true
        $req.MaximumAutomaticRedirections = 10
        $req.Timeout = ([int](Get-ConfigValue -Path 'download.timeoutSeconds' -Default 45)) * 1000
        $req.ReadWriteTimeout = ([int](Get-ConfigValue -Path 'download.readTimeoutSeconds' -Default 120)) * 1000
        $req.KeepAlive = $false
        if ($existing -gt 0) {
            try { $req.AddRange($existing) } catch { $existing = 0 }
        }
        $proxyUrl = [string](Get-ConfigValue -Path 'download.proxy' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($proxyUrl)) {
            $req.Proxy = New-Object Net.WebProxy($proxyUrl, $true)
        }

        $resp = $null
        $stream = $null
        $fs = $null
        try {
            $resp = $req.GetResponse()
        } catch {
            $msg = $_.Exception.Message
            if ($existing -gt 0) {
                Write-Debug2 "续传失败，重新完整下载: $msg"
                Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
                continue
            }
            throw
        }

        try {
            $statusCode = [int]$resp.StatusCode
            $total = 0
            $contentRange = [string]$resp.Headers['Content-Range']
            if ($contentRange -match '/(\d+)\s*$') {
                $total = [long]$Matches[1]
            } elseif ($resp.ContentLength -gt 0) {
                $total = [long]$resp.ContentLength + $existing
            }

            $append = $false
            if ($existing -gt 0 -and $statusCode -eq 206) { $append = $true }
            if ($existing -gt 0 -and $statusCode -ne 206) {
                Write-Debug2 "服务端不支持断点续传，重新下载"
                $existing = 0
            }

            $mode = [IO.FileMode]::Create
            if ($append) { $mode = [IO.FileMode]::Append }
            $fs = New-Object IO.FileStream($part, $mode, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $stream = $resp.GetResponseStream()
            $buffer = New-Object byte[] 131072
            $done = $existing
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $lastReport = 0
            while ($true) {
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                $fs.Write($buffer, 0, $read)
                $done += $read
                if (($sw.ElapsedMilliseconds - $lastReport) -gt 800) {
                    $lastReport = $sw.ElapsedMilliseconds
                    $status = (Format-FileSize -Bytes $done)
                    if ($total -gt 0) {
                        $status = "$status / " + (Format-FileSize -Bytes $total)
                        $pct = [int](($done * 100) / $total)
                        if ($pct -gt 100) { $pct = 100 }
                        Write-Progress -Activity $activity -Status $status -PercentComplete $pct
                    } else {
                        Write-Progress -Activity $activity -Status $status
                    }
                }
            }
            $fs.Flush()
            $fs.Close()
            $fs = $null
            Write-Progress -Activity $activity -Completed

            $actual = (Get-Item -LiteralPath $part).Length
            if ($total -gt 0 -and $actual -ne $total) {
                throw "下载不完整: $actual / $total 字节"
            }
            if ($ExpectedSize -gt 0 -and $actual -ne $ExpectedSize) {
                throw "文件大小与预期不符: $actual / $ExpectedSize 字节"
            }

            if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
            Move-Item -LiteralPath $part -Destination $OutFile -Force
            return @{ Success = $true; Size = $actual; Url = $Url }
        } catch {
            if ($fs) { try { $fs.Close() } catch { } }
            Write-Progress -Activity $activity -Completed
            throw
        } finally {
            if ($stream) { try { $stream.Close() } catch { } }
            if ($resp) { try { $resp.Close() } catch { } }
        }
    }
    throw "下载失败: $Url"
}

function Invoke-BitsDownload {
    param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string]$OutFile)
    if (-not (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue)) { throw 'BITS 不可用' }
    if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
    $job = $null
    try {
        $job = Start-BitsTransfer -Source $Url -Destination $OutFile -Asynchronous -ErrorAction Stop
        while ($job.JobState -in @('Connecting', 'Transferring', 'TransientError')) {
            Start-Sleep -Milliseconds 900
            $job = Get-BitsTransfer -Id $job.Id
            $pct = 0
            if ($job.BytesTotal -gt 0) { $pct = [int](($job.BytesTransferred * 100) / $job.BytesTotal) }
            Write-Progress -Activity "BITS 下载" -Status ((Format-FileSize -Bytes $job.BytesTransferred)) -PercentComplete $pct
        }
        Write-Progress -Activity "BITS 下载" -Completed
        if ($job.JobState -ne 'Transferred') { throw "BITS 状态异常: $($job.JobState)" }
        Complete-BitsTransfer -BitsJob $job
        return @{ Success = $true; Size = (Get-Item -LiteralPath $OutFile).Length; Url = $Url }
    } catch {
        Write-Progress -Activity "BITS 下载" -Completed
        # $job 可能为 $null（例如任务根本没能创建），此时不要再去调用 Remove-BitsTransfer，
        # 否则会用 "Cannot validate argument on parameter 'JobId'" 覆盖真正的错误原因。
        if ($job) {
            try { Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue } catch { }
        }
        throw
    }
}

function Get-HttpStatusOfError {
    # 从异常里尽力取出 HTTP 状态码（0 表示不是 HTTP 层面的错误，例如超时/连接被重置）
    param($ErrorRecord)
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($resp -and $resp.StatusCode) { return [int]$resp.StatusCode }
    } catch { }
    try {
        if ($ErrorRecord.Exception.InnerException -and $ErrorRecord.Exception.InnerException.Response) {
            return [int]$ErrorRecord.Exception.InnerException.Response.StatusCode
        }
    } catch { }
    return 0
}

function Get-ProxyDescription {
    $configured = [string](Get-ConfigValue -Path 'download.proxy' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($configured)) { return "配置代理 $configured" }
    try {
        $p = [Net.WebRequest]::DefaultWebProxy
        if ($p) {
            $uri = $p.GetProxy('https://download.jetbrains.com')
            if ($uri) { return "系统默认代理 $uri" }
        }
    } catch { }
    return '未使用代理（直连）'
}

function Get-RemoteFile {
    param(
        [Parameter(Mandatory = $true)][string[]]$Urls,
        [Parameter(Mandatory = $true)][string]$Destination,
        [long]$ExpectedSize = 0,
        [string]$Label = '',
        [switch]$ForceDownload
    )
    $dir = Split-Path -Parent $Destination
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    if ((Test-Path -LiteralPath $Destination) -and (-not $ForceDownload)) {
        $size = (Get-Item -LiteralPath $Destination).Length
        if ($ExpectedSize -gt 0) {
            if ($size -eq $ExpectedSize) {
                Write-Info "使用缓存文件 $([IO.Path]::GetFileName($Destination))（$((Format-FileSize -Bytes $size))）"
                return @{ Success = $true; Size = $size; Url = 'cache'; Cached = $true }
            }
            Write-Warn "缓存文件大小异常，重新下载: $((Format-FileSize -Bytes $size))"
        } elseif ($size -gt 0) {
            Write-Info "使用缓存文件 $([IO.Path]::GetFileName($Destination))（$((Format-FileSize -Bytes $size))）"
            return @{ Success = $true; Size = $size; Url = 'cache'; Cached = $true }
        }
    }

    if ($script:Options -and $script:Options.Offline) {
        throw "离线模式下缺少缓存文件: $Destination"
    }
    if ($script:Options -and $script:Options.DryRun) {
        Write-Info "[试运行] 下载 $($Urls[0]) -> $Destination"
        return @{ Success = $true; Size = 0; Url = $Urls[0]; DryRun = $true }
    }

    $allCandidates = @($Urls | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

    # 预检（HEAD）：可用的排前面，失败的排后面但仍会尝试一次（有的服务器不支持 HEAD）
    $reachable = New-Object Collections.ArrayList
    $unreachable = New-Object Collections.ArrayList
    $probeInfo = @{}
    $probeText = New-Object Collections.ArrayList
    foreach ($url in $allCandidates) {
        $probe = Test-RemoteUrl -Url $url
        $probeInfo[$url] = $probe
        [void]$probeText.Add(("  {0,-14} {1}" -f $probe.Text, $url))
        if ($probe.Ok) {
            [void]$reachable.Add($url)
        } else {
            [void]$unreachable.Add($url)
            # 用 Info 级别：成功时只是说明某个镜像不可用，失败时下面的详细报告会完整列出
            Write-Info ("候选地址不可用（{0}）: {1}" -f $probe.Text, $url)
        }
    }
    $candidates = @($reachable.ToArray()) + @($unreachable.ToArray())
    if ($reachable.Count -gt 0) {
        Write-Debug2 ("可用下载地址（按优先级）:" + [Environment]::NewLine + (($probeText) -join [Environment]::NewLine))
    } else {
        Write-Warn '所有候选地址预检均未通过，将逐个实际尝试（部分服务器不支持 HEAD 请求）'
    }

    $retries = [int](Get-ConfigValue -Path 'download.retries' -Default 3)
    $httpErrors = New-Object Collections.ArrayList
    $lastError = ''

    foreach ($url in $candidates) {
        # 预检就是传输层失败（超时/DNS）的地址，只尝试一次，避免长时间空等
        $urlRetries = $retries
        if ($probeInfo.ContainsKey($url) -and -not $probeInfo[$url].Ok -and $probeInfo[$url].Status -eq 0) { $urlRetries = 1 }
        for ($i = 1; $i -le $urlRetries; $i++) {
            try {
                Write-Info "下载第 $i 次尝试: $url"
                $r = Invoke-StreamDownload -Url $url -OutFile $Destination -ExpectedSize $ExpectedSize -Label $Label
                if ($r.Success) {
                    Write-Ok "下载完成: $([IO.Path]::GetFileName($Destination))（$((Format-FileSize -Bytes $r.Size))）"
                    return $r
                }
            } catch {
                $status = Get-HttpStatusOfError -ErrorRecord $_
                if ($status -gt 0) {
                    $lastError = "HTTP $status  $url"
                    if (-not $httpErrors.Contains($lastError)) { [void]$httpErrors.Add($lastError) }
                } else {
                    $lastError = $_.Exception.Message
                }
                Write-Warn "下载失败: $lastError"
                # 404/410 说明地址本身不存在，重试无意义
                if ($status -eq 404 -or $status -eq 410) { break }
                if ($i -lt $urlRetries) { Start-Sleep -Seconds (2 * $i) }
            }
        }
        # BITS 兜底只对“传输层”故障有意义；HTTP 4xx 换 BITS 也一样失败
        $skipBits = $false
        foreach ($e in $httpErrors) { if ($e -like "*$url") { $skipBits = $true } }
        if ((-not $skipBits) -and [bool](Get-ConfigValue -Path 'download.useBitsFallback' -Default $true)) {
            try {
                Write-Info "尝试使用 BITS 传输: $url"
                $r = Invoke-BitsDownload -Url $url -OutFile $Destination
                if ($r.Success) {
                    Write-Ok "BITS 下载完成: $([IO.Path]::GetFileName($Destination))（$((Format-FileSize -Bytes $r.Size))）"
                    return $r
                }
            } catch {
                Write-Debug2 "BITS 失败: $($_.Exception.Message)"
            }
        }
    }

    $summary = New-Object Collections.ArrayList
    [void]$summary.Add("组件 $Label 下载失败：所有候选地址都不可用")
    [void]$summary.Add("网络出口：$(Get-ProxyDescription)")
    [void]$summary.Add('地址探测结果：')
    foreach ($t in $probeText) { [void]$summary.Add($t) }
    [void]$summary.Add("目标文件名：$([IO.Path]::GetFileName($Destination))")
    [void]$summary.Add("缓存目录：  $dir")
    [void]$summary.Add('处理建议：')
    [void]$summary.Add('  1) 若内网需要代理：在 config\user.json 里设置 "download": { "proxy": "http://主机:端口" }')
    [void]$summary.Add('  2) 若确实下载不到：手工下载上面的地址，另存为「目标文件名」放进缓存目录，然后重跑脚本（会自动复用缓存）')
    [void]$summary.Add('  3) 也可临时在配置里把该组件 enabled 设为 false 跳过')
    $notFoundCount = 0
    foreach ($u in $allCandidates) {
        $p = $probeInfo[$u]
        if ($p -and [int]$p.Status -eq 404) { $notFoundCount++ }
    }
    if (@($allCandidates).Count -gt 0 -and $notFoundCount -eq @($allCandidates).Count) {
        [void]$summary.Add('  !! 所有候选都返回 HTTP 404：这些官方地址本身是存在的，404 大概率不是「文件缺失」。')
        [void]$summary.Add('     常见原因是出口网络/代理把请求劫持后统一回 404：请检查本机 hosts、DNS、防火墙与 download.proxy，')
        [void]$summary.Add('     并在能正常上网的机器上用 curl.exe -I <地址> 对比（应返回 200）。')
    }
    throw (($summary) -join [Environment]::NewLine)
}

function Test-RemoteUrl {
    param([Parameter(Mandatory = $true)][string]$Url, [int]$TimeoutSeconds = 20)
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.Method = 'HEAD'
        $req.UserAgent = $script:UserAgent
        $req.AllowAutoRedirect = $true
        $req.MaximumAutomaticRedirections = 10
        $req.Timeout = $TimeoutSeconds * 1000
        $proxyUrl = [string](Get-ConfigValue -Path 'download.proxy' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($proxyUrl)) { $req.Proxy = New-Object Net.WebProxy($proxyUrl, $true) }
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $len = $resp.ContentLength
        $resp.Close()
        return @{ Ok = ($code -ge 200 -and $code -lt 400); Status = $code; Length = $len; Text = "HTTP $code" }
    } catch {
        $status = Get-HttpStatusOfError -ErrorRecord $_
        $text = 'HTTP ' + $status
        if ($status -eq 0) {
            $msg = $_.Exception.Message
            if ($msg.Length -gt 28) { $msg = $msg.Substring(0, 28) }
            $text = $msg
        }
        return @{ Ok = $false; Status = $status; Length = 0; Text = $text; Error = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------------------
# 解压
# ---------------------------------------------------------------------------
function Expand-ArchiveTo {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Force
    )
    if (-not (Test-Path -LiteralPath $Archive)) { throw "压缩包不存在: $Archive" }
    if ($script:Options -and $script:Options.DryRun) {
        Write-Info "[试运行] 解压 $([IO.Path]::GetFileName($Archive)) -> $Destination"
        return
    }

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (Test-Path -LiteralPath $Destination) {
        if (-not $Force) { throw "目标目录已存在: $Destination" }
        Remove-PathRobust -Path $Destination
    }

    $tmp = Join-Path $parent ('.extract-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $ok = $false
        $tar = Get-Command -Name tar.exe -ErrorAction SilentlyContinue
        if ($tar) {
            $r = Invoke-Process -FilePath $tar.Source -Arguments @('-xf', $Archive, '-C', $tmp) -TimeoutSeconds 7200
            $ok = ($r.ExitCode -eq 0)
            if (-not $ok) {
                Write-Debug2 "tar 解压返回 $($r.ExitCode): $($r.StdErr)"
            }
        }
        if (-not $ok) {
            Write-Debug2 "使用 Expand-Archive 解压"
            Expand-Archive -LiteralPath $Archive -DestinationPath $tmp -Force
        }

        $items = @(Get-ChildItem -LiteralPath $tmp -Force)
        if ($items.Count -eq 0) { throw "压缩包内容为空: $Archive" }

        $source = $tmp
        if ($items.Count -eq 1 -and $items[0].PSIsContainer) { $source = $items[0].FullName }

        if ($source -eq $tmp) {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
            foreach ($item in $items) {
                Move-Item -LiteralPath $item.FullName -Destination $Destination -Force
            }
        } else {
            Move-Item -LiteralPath $source -Destination $Destination -Force
        }
        Write-Debug2 "解压完成 $Archive -> $Destination"
    } finally {
        Remove-PathRobust -Path $tmp
    }
}

function Find-FileIn {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$MaxDepth = 2
    )
    if (-not (Test-Path -LiteralPath $Root)) { return $null }
    $direct = Join-Path $Root $Name
    if (Test-Path -LiteralPath $direct) { return $direct }

    $found = @(Get-ChildItem -LiteralPath $Root -Filter $Name -Recurse -File -ErrorAction SilentlyContinue)
    $best = $null
    $bestDepth = [int]::MaxValue
    foreach ($f in $found) {
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\')
        $depth = ($rel -split '\\').Count - 1
        if ($depth -le $MaxDepth -and $depth -lt $bestDepth) {
            $best = $f
            $bestDepth = $depth
        }
    }
    if ($best) { return $best.FullName }
    return $null
}

function Test-PeImage {
    # 只读文件头，判断“是不是一个结构完整的 Windows 可执行镜像”，不执行文件本身。
    # 用途：安装器启动前的预检，以及启动失败（Win32 错误 193/216）时的归因诊断。
    # 实测签名：0 字节/PE 结构残缺 → 193；有 MZ 但缺 PE 头 → 216。
    param([Parameter(Mandatory = $true)][string]$Path)
    $result = @{ Valid = $false; Machine = 0; MachineText = ''; Reason = '' }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { $result.Reason = '文件不存在'; return $result }
        $len = (Get-Item -LiteralPath $Path -Force).Length
        if ($len -lt 0x40) { $result.Reason = "文件只有 $len 字节（很可能已被安全软件清空/隔离）"; return $result }
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $br = New-Object IO.BinaryReader($fs)
            $mz = $br.ReadBytes(2)
            if ($mz.Length -lt 2 -or $mz[0] -ne 0x4D -or $mz[1] -ne 0x5A) {
                $result.Reason = '缺少 MZ 头（不是 Windows 可执行文件，内容可能已被替换）'
                return $result
            }
            $fs.Position = 0x3C
            $peOff = $br.ReadInt32()
            if ($peOff -le 0 -or $peOff -ge ($len - 24)) { $result.Reason = 'PE 头偏移越界（镜像结构损坏）'; return $result }
            $fs.Position = $peOff
            $sig = $br.ReadBytes(4)
            if ($sig.Length -lt 4 -or $sig[0] -ne 0x50 -or $sig[1] -ne 0x45 -or $sig[2] -ne 0 -or $sig[3] -ne 0) {
                $result.Reason = 'PE 签名缺失（镜像结构损坏）'
                return $result
            }
            $machine = $br.ReadUInt16()
            $result.Machine = $machine
            $result.MachineText = switch ($machine) {
                0x014C { 'x86 32 位' }
                0x8664 { 'x64 64 位' }
                0xAA64 { 'ARM64' }
                default { ('0x{0:X4}' -f $machine) }
            }
            $result.Valid = $true
            return $result
        } finally { $fs.Dispose() }
    } catch {
        $result.Reason = "读取失败: $($_.Exception.Message)"
        return $result
    }
}

function Format-InstallerStartError {
    # 安装器 Process.Start 抛异常时的归因报错：结合启动前后的 PE 校验结果与 Win32 错误码，
    # 把难懂的 “not a valid application for this OS platform” 翻译成能直接行动的中文提示。
    param(
        [Parameter(Mandatory = $true)]$ErrorRecord,
        [Parameter(Mandatory = $true)][string]$SetupFile,
        [hashtable]$PeBefore = $null,
        # Shell 方式（双击同路径）重试过仍然失败——基本可断定是行为拦截
        [switch]$ShellTried
    )
    $lines = New-Object Collections.ArrayList
    $code = 0
    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.PSObject.Properties['NativeErrorCode']) {
        $code = [int]$ErrorRecord.Exception.NativeErrorCode
    } elseif ($ErrorRecord.Exception.InnerException -and $ErrorRecord.Exception.InnerException.PSObject.Properties['NativeErrorCode']) {
        $code = [int]$ErrorRecord.Exception.InnerException.NativeErrorCode
    }
    [void]$lines.Add("安装器无法启动（Win32 错误 $code）: $SetupFile")
    $pe = Test-PeImage -Path $SetupFile
    if ($pe.Valid) {
        [void]$lines.Add("当前文件完好（$($pe.MachineText)）。")
        if ($null -ne $PeBefore -and -not $PeBefore.Valid) {
            [void]$lines.Add('注意：启动前预检就已经失败，文件在解压后、启动前即被拦截或替换。')
        }
        if ($code -eq 193 -and [Environment]::Is64BitOperatingSystem -and
            -not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'SysWOW64\kernel32.dll'))) {
            [void]$lines.Add('系统缺少 32 位兼容层（SysWOW64），无法运行 32 位安装器——精简版/魔改系统常见，请更换完整版系统镜像后重试。')
        } elseif ($code -eq 193 -and $ShellTried) {
            [void]$lines.Add('直接启动与 Shell 启动（双击同路径）均被拒绝，而文件完好、隔离区通常也无记录——这是安全软件行为拦截的典型形态：只拦“控制台进程静默拉起安装器”，不拦用户双击（360/火绒/Defender 主动防御均可能）。')
            [void]$lines.Add('处理建议：查看安全软件的拦截/主动防御记录并添加信任；或手动双击缓存目录里的安装器完成安装后重跑本脚本（会自动识别已安装并跳过）。')
        } elseif ($code -eq 193) {
            [void]$lines.Add('镜像结构完整却被系统拒绝执行，通常是安全软件策略（如 Smart App Control/组策略/杀软主动防御）拦截，请查看安全软件的拦截记录。')
        } else {
            [void]$lines.Add('请查看完整报错信息定位原因。')
        }
    } else {
        [void]$lines.Add("当前文件异常: $($pe.Reason)。")
        if ($null -ne $PeBefore -and $PeBefore.Valid) {
            [void]$lines.Add('启动前预检还是完好的——文件在启动前一刻被清空/损坏，几乎可以确定是杀毒软件实时防护拦截了安装器。')
        }
        [void]$lines.Add('处理建议：查看杀毒软件的查杀/隔离记录并恢复或添加信任；把脚本缓存目录加入白名单；重跑安装（怀疑缓存包损坏可加 -Force 重新下载）。')
    }
    return (($lines) -join [Environment]::NewLine)
}

# ---------------------------------------------------------------------------
# 托管配置块
# ---------------------------------------------------------------------------
function Set-ManagedBlock {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Lines,
        [string]$CommentChar = '#'
    )
    $begin = "$CommentChar >>> $($script:ToolName):$Id >>>"
    $end = "$CommentChar <<< $($script:ToolName):$Id <<<"

    $content = @()
    if (Test-Path -LiteralPath $File) {
        try { $content = @([IO.File]::ReadAllLines($File, [Text.Encoding]::UTF8)) } catch { $content = @() }
    }

    $out = New-Object Collections.ArrayList
    $skipping = $false
    foreach ($line in $content) {
        if ($line -eq $begin) { $skipping = $true; continue }
        if ($line -eq $end) { $skipping = $false; continue }
        if (-not $skipping) { [void]$out.Add($line) }
    }
    while ($out.Count -gt 0 -and [string]::IsNullOrWhiteSpace([string]$out[$out.Count - 1])) {
        $out.RemoveAt($out.Count - 1)
    }
    [void]$out.Add('')
    [void]$out.Add($begin)
    foreach ($l in $Lines) { [void]$out.Add($l) }
    [void]$out.Add($end)
    [void]$out.Add('')

    if ($script:Options -and $script:Options.DryRun) {
        Write-Info "[试运行] 写入配置块 $Id -> $File"
        return
    }
    $dir = Split-Path -Parent $File
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllLines($File, $out.ToArray(), (New-Object Text.UTF8Encoding $false))
}

function Remove-ManagedBlock {
    param([Parameter(Mandatory = $true)][string]$File, [Parameter(Mandatory = $true)][string]$Id, [string]$CommentChar = '#')
    if (-not (Test-Path -LiteralPath $File)) { return }
    $begin = "$CommentChar >>> $($script:ToolName):$Id >>>"
    $end = "$CommentChar <<< $($script:ToolName):$Id <<<"
    $content = @([IO.File]::ReadAllLines($File, [Text.Encoding]::UTF8))
    $out = New-Object Collections.ArrayList
    $skipping = $false
    foreach ($line in $content) {
        if ($line -eq $begin) { $skipping = $true; continue }
        if ($line -eq $end) { $skipping = $false; continue }
        if (-not $skipping) { [void]$out.Add($line) }
    }
    [IO.File]::WriteAllLines($File, $out.ToArray(), (New-Object Text.UTF8Encoding $false))
}

# ---------------------------------------------------------------------------
# 用户级环境变量（HKCU\Environment）
# ---------------------------------------------------------------------------
function Get-UserEnvRaw {
    param([Parameter(Mandatory = $true)][string]$Name)
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
        if (-not $key) { return @{ Value = ''; Kind = 'String'; Exists = $false } }
        $value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $value) { return @{ Value = ''; Kind = 'String'; Exists = $false } }
        $kind = 'String'
        try { $kind = $key.GetValueKind($Name).ToString() } catch { }
        return @{ Value = [string]$value; Kind = $kind; Exists = $true }
    } catch {
        return @{ Value = ''; Kind = 'String'; Exists = $false }
    } finally {
        if ($key) { $key.Close() }
    }
}

function Set-UserEnvRaw {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value,
        [string]$Kind = 'String'
    )
    if ($script:Options -and $script:Options.DryRun) {
        Write-Info "[试运行] 设置用户环境变量 $Name = $Value"
        return
    }
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    if (-not $key) { throw "无法打开注册表 HKCU\Environment" }
    try {
        $regKind = [Microsoft.Win32.RegistryValueKind]::String
        if ($Kind -eq 'ExpandString') { $regKind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
        $key.SetValue($Name, $Value, $regKind)
    } finally {
        $key.Close()
    }
}

function Send-EnvironmentChanged {
    try {
        if (-not ('JavaDevEnv.NativeMethods' -as [type])) {
            $code = @'
using System;
using System.Runtime.InteropServices;
namespace JavaDevEnv {
    public static class NativeMethods {
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
        public static void Broadcast() {
            UIntPtr result;
            SendMessageTimeout((IntPtr)0xffff, 0x001A, UIntPtr.Zero, "Environment", 0x0002, 3000, out result);
        }
    }
}
'@
            Add-Type -TypeDefinition $code -ErrorAction Stop | Out-Null
        }
        [JavaDevEnv.NativeMethods]::Broadcast()
        Write-Debug2 '已广播环境变量变更消息'
    } catch {
        Write-Debug2 "广播环境变量变更失败(可忽略): $($_.Exception.Message)"
    }
}

function Add-UserPathEntry {
    param([Parameter(Mandatory = $true)][string]$Entry, [string]$Reason = '')
    if ([string]::IsNullOrWhiteSpace($Entry)) { return $false }
    $entry = $Entry.Trim().TrimEnd('\')
    $current = Get-UserEnvRaw -Name 'Path'
    $raw = $current.Value
    $kind = 'String'
    if ($current.Kind -eq 'ExpandString') { $kind = 'ExpandString' }

    $items = @()
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $items = @($raw -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $expandedEntry = [Environment]::ExpandEnvironmentVariables($entry).TrimEnd('\')
    foreach ($item in $items) {
        $t = $item.Trim().TrimEnd('\')
        if ($t -ieq $entry) { return $false }
        try {
            if ([Environment]::ExpandEnvironmentVariables($t).TrimEnd('\') -ieq $expandedEntry) { return $false }
        } catch { }
    }

    $newValue = (@($items) + $entry) -join ';'
    if ($newValue.Length -gt 1800) {
        Write-Warn "用户 PATH 长度已达 $($newValue.Length) 字符，接近 Windows 限制，建议清理无用项"
    }
    Set-UserEnvRaw -Name 'Path' -Value $newValue -Kind $kind
    $note = ''
    if ($Reason) { $note = "（$Reason）" }
    Write-Info "已加入用户 PATH: $entry$note"
    return $true
}

function Remove-UserPathEntry {
    param([Parameter(Mandatory = $true)][string]$Entry)
    $entry = $Entry.Trim().TrimEnd('\')
    $current = Get-UserEnvRaw -Name 'Path'
    if (-not $current.Exists) { return $false }
    $items = @($current.Value -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $kept = @($items | Where-Object { $_.Trim().TrimEnd('\') -ine $entry })
    if ($kept.Count -eq $items.Count) { return $false }
    Set-UserEnvRaw -Name 'Path' -Value (($kept) -join ';') -Kind $current.Kind
    Write-Info "已从用户 PATH 移除: $entry"
    return $true
}

function Backup-UserEnvironment {
    param([Parameter(Mandatory = $true)][string]$File, [string[]]$Names = @('Path', 'JAVA_HOME', 'MAVEN_HOME', 'M2_HOME', 'MAVEN_OPTS', 'NPM_CONFIG_PREFIX'))
    $snapshot = @{}
    foreach ($n in $Names) {
        $v = Get-UserEnvRaw -Name $n
        $snapshot[$n] = @{ Value = $v.Value; Kind = $v.Kind; Exists = $v.Exists }
    }
    $payload = @{ timestamp = (Get-Date).ToString('s'); variables = $snapshot }
    $json = $payload | ConvertTo-Json -Depth 8
    $dir = Split-Path -Parent $File
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($File, $json, (New-Object Text.UTF8Encoding $false))
    Write-Info "已备份用户环境变量 -> $File"
    return $File
}

function Restore-UserEnvironment {
    param([Parameter(Mandatory = $true)][string]$File)
    if (-not (Test-Path -LiteralPath $File)) { Write-Warn "找不到环境变量备份: $File"; return $false }
    $payload = [IO.File]::ReadAllText($File, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $vars = ConvertTo-DeepHashtable $payload.variables
    foreach ($name in @($vars.Keys)) {
        $item = $vars[$name]
        if ($item.Exists) {
            Set-UserEnvRaw -Name $name -Value ([string]$item.Value) -Kind ([string]$item.Kind)
            Write-Info "已还原 $name"
        } else {
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
            if ($key) {
                try { $key.DeleteValue($name, $false) } catch { }
                $key.Close()
            }
            Write-Info "已删除 $name"
        }
    }
    Send-EnvironmentChanged
    return $true
}

# ---------------------------------------------------------------------------
# 快捷方式
# ---------------------------------------------------------------------------
function Get-ShortcutDirectory {
    param([string]$Kind = 'Desktop')
    $configured = [string](Get-ConfigValue -Path 'shortcuts.directory' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        return [Environment]::ExpandEnvironmentVariables($configured)
    }
    if ($Kind -eq 'StartMenu') {
        return (Join-Path ([Environment]::GetFolderPath('Programs')) 'JavaDevEnv')
    }
    return [Environment]::GetFolderPath('Desktop')
}

function New-Shortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [string]$Arguments = '',
        [string]$WorkingDirectory = '',
        [string]$IconLocation = '',
        [string]$Description = '',
        [int]$WindowStyle = 1
    )
    if ($script:Options -and $script:Options.DryRun) {
        Write-Info "[试运行] 创建快捷方式 $Path"
        return $false
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut($Path)
        $lnk.TargetPath = $TargetPath
        if (-not [string]::IsNullOrWhiteSpace($Arguments)) { $lnk.Arguments = $Arguments }
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $lnk.WorkingDirectory = $WorkingDirectory }
        if (-not [string]::IsNullOrWhiteSpace($IconLocation)) { $lnk.IconLocation = $IconLocation }
        if (-not [string]::IsNullOrWhiteSpace($Description)) { $lnk.Description = $Description }
        $lnk.WindowStyle = $WindowStyle
        $lnk.Save()
        Write-Info "创建快捷方式 $([IO.Path]::GetFileName($Path))"
        return $true
    } catch {
        Write-Warn "创建快捷方式失败 $Path : $($_.Exception.Message)"
        return $false
    } finally {
        if ($shell) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { } }
    }
}

function Find-ShortcutByTarget {
    # 查找目录下是否已有指向同一目标的快捷方式（用于避免和软件自带安装器重复创建）
    param([Parameter(Mandatory = $true)][string]$Directory, [Parameter(Mandatory = $true)][string]$TargetPath)
    if ([string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Path -LiteralPath $Directory)) { return '' }
    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($f in @(Get-ChildItem -LiteralPath $Directory -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
            try {
                $t = [string]$shell.CreateShortcut($f.FullName).TargetPath
                if ($t -and ($t.TrimEnd('\') -ieq $TargetPath.TrimEnd('\'))) { return $f.FullName }
            } catch { }
        }
    } catch {
        Write-Debug2 "扫描快捷方式失败（$Directory）: $($_.Exception.Message)"
    } finally {
        if ($shell) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { } }
    }
    return ''
}

function Remove-Shortcut {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if ($script:Options -and $script:Options.DryRun) { Write-Info "[试运行] 删除快捷方式 $Path"; return $true }
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        Write-Info "删除快捷方式 $([IO.Path]::GetFileName($Path))"
        return $true
    } catch {
        Write-Warn "删除快捷方式失败 $Path : $($_.Exception.Message)"
        return $false
    }
}

# ---------------------------------------------------------------------------
# 组件标记 / 探测
# ---------------------------------------------------------------------------
function Get-ComponentMarkerPath {
    param([Parameter(Mandatory = $true)][string]$Target)
    return (Join-Path $Target '.javadevenv.json')
}

function Set-ComponentMarker {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$Version = '',
        [string]$Source = '',
        [string]$Origin = '',
        [hashtable]$Extra = @{}
    )
    $payload = @{
        key         = $Key
        version     = $Version
        source      = $Source
        origin      = $Origin
        installedAt = (Get-Date).ToString('s')
        tool        = "$($script:ToolName) $($script:ToolVersion)"
        extra       = $Extra
    }
    $json = $payload | ConvertTo-Json -Depth 6
    $file = Get-ComponentMarkerPath -Target $Target
    if ($script:Options -and $script:Options.DryRun) { return }
    try { [IO.File]::WriteAllText($file, $json, (New-Object Text.UTF8Encoding $false)) } catch { }
}

function Get-ComponentMarker {
    param([Parameter(Mandatory = $true)][string]$Target)
    $file = Get-ComponentMarkerPath -Target $Target
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        return ([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-EffectivePort {
    # 组件实际使用的端口：优先取安装标记里记录的端口（可能因端口冲突被自动顺延）
    param([hashtable]$Spec, [int]$Default)
    if ($Spec -and $Spec.Target) {
        $marker = Get-ComponentMarker -Target $Spec.Target
        if ($marker -and $marker.extra -and $marker.extra.port) { return [int]$marker.extra.port }
    }
    return $Default
}

function Add-ProcessPath {
    param([Parameter(Mandatory = $true)][string]$Directory)
    if ([string]::IsNullOrWhiteSpace($Directory)) { return }
    if (-not (Test-Path -LiteralPath $Directory)) { return }
    $parts = @($env:PATH -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($p in $parts) {
        if ($p.TrimEnd('\') -ieq $Directory.TrimEnd('\')) { return }
    }
    $env:PATH = "$Directory;$env:PATH"
}

function Get-FirstExistingPath {
    param([string[]]$Candidates)
    foreach ($c in @($Candidates)) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        try {
            $p = [Environment]::ExpandEnvironmentVariables($c)
            if (Test-Path -LiteralPath $p) { return $p }
        } catch { }
    }
    return $null
}
