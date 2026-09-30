# ===========================================================================
#  10-Catalog.ps1  —  组件目录、版本解析、探测、安装引擎
# ===========================================================================

# ---------------------------------------------------------------------------
# 模板 / 工具函数
# ---------------------------------------------------------------------------
function Format-ComponentTemplate {
    param([string]$Template, [hashtable]$Values)
    if ([string]::IsNullOrWhiteSpace($Template)) { return '' }
    $s = $Template
    foreach ($k in @($Values.Keys)) { $s = $s.Replace('{' + $k + '}', [string]$Values[$k]) }
    return $s
}

function Expand-TemplateList {
    param([string[]]$Templates, [hashtable]$Values)
    $out = New-Object Collections.ArrayList
    foreach ($t in @($Templates)) {
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        $u = Format-ComponentTemplate -Template $t -Values $Values
        if ($u -match '\{[a-zA-Z]+\}') { continue }    # 还有未替换占位符 → 跳过
        [void]$out.Add($u)
    }
    return , $out.ToArray()
}

function Test-PreferMirrors {
    $mode = Get-ConfigValue -Path 'preferMirrors' -Default 'auto'
    if ($mode -is [bool]) { return [bool]$mode }
    $s = [string]$mode
    if ($s -ieq 'true') { return $true }
    if ($s -ieq 'false') { return $false }
    try {
        $culture = (Get-Culture).Name
        if ($culture -like 'zh*') { return $true }
    } catch { }
    return $false
}

function Get-RestJson {
    # 带重试的 JSON 接口请求（JetBrains / Adoptium / GitHub 都走这里）；
    # 这些接口偶发超时、断流、返回空响应，重试几次可以避免误退到“写死版本”的兜底分支。
    param([Parameter(Mandatory = $true)][string]$Url, [int]$TimeoutSeconds = 20, [int]$Retries = 2)
    $lastError = ''
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $resp = $null
        try {
            $req = [Net.HttpWebRequest]::Create($Url)
            $req.Method = 'GET'
            $req.UserAgent = $script:UserAgent
            $req.Accept = 'application/json'
            $req.AllowAutoRedirect = $true
            $req.MaximumAutomaticRedirections = 10
            $req.Timeout = $TimeoutSeconds * 1000
            $req.ReadWriteTimeout = $TimeoutSeconds * 1000
            $req.KeepAlive = $false
            try {
                $req.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
            } catch { }
            $proxyUrl = [string](Get-ConfigValue -Path 'download.proxy' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($proxyUrl)) { $req.Proxy = New-Object Net.WebProxy($proxyUrl, $true) }

            $resp = $req.GetResponse()
            $reader = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
            $text = $reader.ReadToEnd()
            $reader.Close()
            Write-Debug2 "接口响应 $([int]$resp.StatusCode) 长度 $($text.Length): $Url"
            # 空响应也要重试（代理/网关偶发返回 200 空正文，会导致版本解析“静默失败”）
            if ([string]::IsNullOrWhiteSpace($text)) { throw '响应内容为空' }
            return ($text | ConvertFrom-Json)
        } catch {
            $lastError = $_.Exception.Message
            Write-Debug2 "接口请求失败（第 $attempt/$Retries 次）$Url : $lastError"
            if ($attempt -lt $Retries) { Start-Sleep -Milliseconds (600 * $attempt) }
        } finally {
            if ($resp) { try { $resp.Close() } catch { } }
        }
    }
    throw "接口请求失败（已重试 $Retries 次）$Url : $lastError"
}

function Get-RestText {
    # 带重试的纯文本接口请求（dsh 桌面端的官方更新清单是 YAML，不能按 JSON 解析）
    param([Parameter(Mandatory = $true)][string]$Url, [int]$TimeoutSeconds = 20, [int]$Retries = 2, [string]$Accept = '*/*')
    $lastError = ''
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $resp = $null
        try {
            $req = [Net.HttpWebRequest]::Create($Url)
            $req.Method = 'GET'
            $req.UserAgent = $script:UserAgent
            $req.Accept = $Accept
            $req.AllowAutoRedirect = $true
            $req.MaximumAutomaticRedirections = 10
            $req.Timeout = $TimeoutSeconds * 1000
            $req.ReadWriteTimeout = $TimeoutSeconds * 1000
            $req.KeepAlive = $false
            try {
                $req.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
            } catch { }
            $proxyUrl = [string](Get-ConfigValue -Path 'download.proxy' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($proxyUrl)) { $req.Proxy = New-Object Net.WebProxy($proxyUrl, $true) }

            $resp = $req.GetResponse()
            $reader = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
            $text = $reader.ReadToEnd()
            $reader.Close()
            Write-Debug2 "接口响应 $([int]$resp.StatusCode) 长度 $($text.Length): $Url"
            if ([string]::IsNullOrWhiteSpace($text)) { throw '响应内容为空' }
            return $text
        } catch {
            $lastError = $_.Exception.Message
            Write-Debug2 "接口请求失败（第 $attempt/$Retries 次）$Url : $lastError"
            if ($attempt -lt $Retries) { Start-Sleep -Milliseconds (600 * $attempt) }
        } finally {
            if ($resp) { try { $resp.Close() } catch { } }
        }
    }
    throw "接口请求失败（已重试 $Retries 次）$Url : $lastError"
}

function Get-ObjectProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $Default
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $Default
}

# ---------------------------------------------------------------------------
# 已有安装探测
# ---------------------------------------------------------------------------
function Get-DetectionRules {
    return @{
        jdk = @{
            Commands  = @('java.exe')
            EnvVars   = @('JAVA_HOME')
            Consumers = @('%ProgramFiles%\Eclipse Adoptium\*', '%ProgramFiles%\Java\*', '%ProgramFiles%\Zulu\*',
                          '%ProgramFiles%\Microsoft\jdk-*', '%ProgramFiles%\Amazon Corretto\*', 'D:\Java\*', 'C:\Java\*', 'D:\Dev\*jdk*')
            NameGlobs = @('jdk*', 'jdk-*', 'zulu*', 'temurin*', 'corretto*', 'Java\*', '*jdk*')
            HomeProbe = 'bin\java.exe'
            VersionCmd = @('-version')
        }
        maven = @{
            Commands  = @('mvn.cmd')
            EnvVars   = @('MAVEN_HOME', 'M2_HOME')
            Consumers = @('%ProgramFiles%\apache-maven-*', 'D:\apache-maven-*', 'C:\apache-maven-*', 'D:\Dev\apache-maven-*')
            NameGlobs = @('apache-maven*', 'maven*', 'Maven*')
            HomeProbe = 'bin\mvn.cmd'
            VersionCmd = @('-v')
        }
        ide = @{
            Commands  = @('idea64.exe')
            EnvVars   = @()
            Consumers = @('%ProgramFiles%\JetBrains\*', '%LOCALAPPDATA%\Programs\*IDEA*', '%LOCALAPPDATA%\JetBrains\*', 'D:\JetBrains\*', 'D:\*IDEA*')
            NameGlobs = @('idea*', 'IDEA*', 'IntelliJ*', 'JetBrains\*', 'JetBrains*')
            HomeProbe = 'bin\idea64.exe'
            VersionCmd = @()
        }
        git = @{
            Commands  = @('git.exe')
            EnvVars   = @()
            Consumers = @('%ProgramFiles%\Git', 'D:\Git', 'C:\Git', 'D:\Program Files\Git')
            NameGlobs = @('Git', 'git*', 'MinGit*', 'PortableGit*')
            HomeProbe = 'cmd\git.exe'
            VersionCmd = @('--version')
        }
        node = @{
            Commands  = @('node.exe')
            EnvVars   = @()
            Consumers = @('%ProgramFiles%\nodejs', 'D:\nodejs', 'C:\nodejs', '%APPDATA%\nvm\*', 'D:\nvm4w\nodejs', 'D:\nvm4w\*')
            NameGlobs = @('nodejs', 'node-*', 'Node*', 'nvm4w\nodejs')
            HomeProbe = 'node.exe'
            VersionCmd = @('-v')
        }
        postgres = @{
            Commands  = @('psql.exe', 'pg_ctl.exe')
            EnvVars   = @('PGHOME', 'PGBIN')
            Consumers = @('%ProgramFiles%\PostgreSQL\*', 'D:\PostgreSQL\*', 'C:\PostgreSQL\*')
            NameGlobs = @('PostgreSQL\*', 'PostgreSQL', 'pgsql*', 'postgres*')
            Registry  = @(@{ Path = 'HKLM:\SOFTWARE\PostgreSQL\Installations\*'; Value = 'Base Directory' },
                          @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\PostgreSQL\Installations\*'; Value = 'Base Directory' })
            HomeProbe = 'bin\pg_ctl.exe'
            VersionCmd = @('-V')
        }
        redis = @{
            Commands  = @('redis-server.exe')
            EnvVars   = @()
            Consumers = @('%ProgramFiles%\Redis', 'D:\Redis', 'C:\Redis', 'D:\redis*')
            NameGlobs = @('Redis', 'redis*', 'Redis-*', 'Memurai*')
            HomeProbe = 'redis-server.exe'
            VersionCmd = @('--version')
        }
        dbeaver = @{
            Commands  = @('dbeaver.exe')
            EnvVars   = @()
            Consumers = @('%ProgramFiles%\DBeaver\*', 'D:\DBeaver\*', 'D:\dbeaver', 'C:\DBeaver\*')
            NameGlobs = @('DBeaver\*', 'DBeaver*', 'dbeaver*')
            HomeProbe = 'dbeaver.exe'
            VersionCmd = @()
        }
        heidisql = @{
            Commands  = @('heidisql.exe')
            EnvVars   = @()
            Consumers = @('%ProgramFiles%\HeidiSQL', 'D:\HeidiSQL', 'C:\HeidiSQL')
            NameGlobs = @('HeidiSQL*', 'heidisql*')
            HomeProbe = 'heidisql.exe'
            VersionCmd = @()
        }
        dsh = @{
            # DSH 桌面端（Electron + NSIS 安装包）：程序名带空格、不在 PATH 上，
            # 主要靠“卸载登记表 + 常见目录”发现；HomeProbe 同时也充当注册表条目的过滤器。
            Commands  = @()
            EnvVars   = @()
            Consumers = @('%LOCALAPPDATA%\Programs\deepseek-harness', '%LOCALAPPDATA%\Programs\DeepSeek Harness',
                          '%ProgramFiles%\DeepSeek Harness', '%ProgramFiles%\deepseek-harness',
                          'D:\Software\DSH', 'C:\Software\DSH')
            NameGlobs = @('DSH', 'DSH*', 'DeepSeek*', 'deepseek*', 'dsh-desktop')
            Registry  = @(@{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'; Value = 'InstallLocation' },
                          @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; Value = 'InstallLocation' },
                          @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Value = 'InstallLocation' })
            HomeProbe = 'DeepSeek Harness.exe'
            VersionCmd = @()
            # 版本号从“卸载”登记里读：GUI 程序不能为了取版本号就去启动它
            VersionRegistry = @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
                                 NameMatch = 'DeepSeek Harness'
                                 Value = 'DisplayVersion' }
        }
        'dsh-cli' = @{
            # 命令行版 dsh（npm 全局包），默认不启用
            Commands  = @('dsh.cmd', 'dsh.exe', 'dsh.ps1')
            EnvVars   = @()
            Consumers = @()
            HomeProbe = 'dsh.cmd'
            VersionCmd = @('--version')
        }
    }
}

function Get-DetectionBaseDirs {
    # 枚举所有固定磁盘 + 常见软件容器目录，用于发现安装在非默认路径下的组件
    if ($script:DetectionBaseDirs) { return $script:DetectionBaseDirs }
    $list = New-Object Collections.ArrayList
    $containers = @('', 'Database', 'Dev', 'Development', 'Env', 'Java', 'Software', 'Tools', 'Program', 'Server', 'App', 'Apps')
    $drives = @()
    try {
        $drives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
            Where-Object { $_.DeviceID } | ForEach-Object { $_.DeviceID + '\' })
    } catch { }
    if ($drives.Count -eq 0) { $drives = @("$env:SystemDrive\") }
    foreach ($drive in $drives) {
        foreach ($container in $containers) {
            $path = $drive
            if ($container) { $path = Join-Path $drive $container }
            if (Test-Path -LiteralPath $path) { [void]$list.Add($path) }
        }
    }
    $script:DetectionBaseDirs = $list.ToArray()
    return , $script:DetectionBaseDirs
}

function Get-HomeFromExe {
    param([string]$ExePath, [int]$Up = 2)
    $p = $ExePath
    for ($i = 0; $i -lt $Up; $i++) {
        $parent = Split-Path -Parent $p
        if ([string]::IsNullOrWhiteSpace($parent)) { return $null }
        $p = $parent
    }
    return $p
}

function Find-ExistingComponent {
    param([Parameter(Mandatory = $true)][string]$Key)
    $rules = (Get-DetectionRules)[$Key]
    if (-not $rules) { return $null }
    $probe = $rules.HomeProbe
    $up = 2
    if ($probe -notmatch '\\') { $up = 1 }

    # 1) 环境变量
    foreach ($varName in @($rules.EnvVars)) {
        $v = [Environment]::GetEnvironmentVariable($varName, 'User')
        if ([string]::IsNullOrWhiteSpace($v)) { $v = [Environment]::GetEnvironmentVariable($varName, 'Machine') }
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        $homeDir = [Environment]::ExpandEnvironmentVariables($v)
        if (Test-Path -LiteralPath (Join-Path $homeDir $probe)) {
            return @{ Home = $homeDir; Source = "环境变量 $varName"; Exe = (Join-Path $homeDir $probe) }
        }
    }
    # 2) PATH 命令
    foreach ($cmd in @($rules.Commands)) {
        $c = Get-Command -Name $cmd -ErrorAction SilentlyContinue
        if (-not $c) { continue }
        $exe = $c.Source
        if (-not $exe) { continue }
        $homeDir = Get-HomeFromExe -ExePath $exe -Up $up
        if ($homeDir -and (Test-Path -LiteralPath (Join-Path $homeDir $probe))) {
            return @{ Home = $homeDir; Source = "PATH ($cmd)"; Exe = $exe }
        }
        if ($homeDir) { return @{ Home = $homeDir; Source = "PATH ($cmd)"; Exe = $exe } }
    }
    # 3) 注册表（PostgreSQL / JDK 等官方安装器会登记）
    foreach ($reg in @($rules.Registry)) {
        if (-not $reg) { continue }
        try {
            foreach ($item in @(Get-ItemProperty -Path $reg.Path -ErrorAction SilentlyContinue)) {
                $value = $item.($reg.Value)
                if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
                $homeDir = [Environment]::ExpandEnvironmentVariables([string]$value)
                if (Test-Path -LiteralPath (Join-Path $homeDir $probe)) {
                    return @{ Home = $homeDir; Source = '注册表'; Exe = (Join-Path $homeDir $probe) }
                }
            }
        } catch { }
    }

    # 4) 常见安装目录（含各磁盘下的常见容器目录）
    $candidates = New-Object Collections.ArrayList
    foreach ($pattern in @($rules.Consumers)) { [void]$candidates.Add([Environment]::ExpandEnvironmentVariables($pattern)) }
    if ($rules.NameGlobs) {
        foreach ($base in @(Get-DetectionBaseDirs)) {
            foreach ($glob in @($rules.NameGlobs)) { [void]$candidates.Add((Join-Path $base $glob)) }
        }
    }
    foreach ($expanded in $candidates) {
        if ([string]::IsNullOrWhiteSpace($expanded)) { continue }
        $dirs = @()
        if ($expanded -match '\*') {
            try {
                $dirs = @(Get-ChildItem -Path $expanded -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            } catch { $dirs = @() }
        } elseif (Test-Path -LiteralPath $expanded) {
            $dirs = @(Get-Item -LiteralPath $expanded -ErrorAction SilentlyContinue)
        }
        foreach ($d in $dirs) {
            if (-not $d) { continue }
            if (Test-Path -LiteralPath (Join-Path $d.FullName $probe)) {
                return @{ Home = $d.FullName; Source = '常见目录'; Exe = (Join-Path $d.FullName $probe) }
            }
        }
    }
    return $null
}

function Get-ComponentVersionString {
    param([hashtable]$Spec)
    $exe = $Spec.ProbePath
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) { return '' }
    $rules = (Get-DetectionRules)[$Spec.DetectKey]
    $cmdArgs = @()
    if ($rules) { $cmdArgs = @($rules.VersionCmd) }
    if ($cmdArgs.Count -eq 0) {
        # 没有命令行取版本的方式（例如 GUI 程序）时，退回注册表里的 DisplayVersion
        if ($rules -and $rules.VersionRegistry) {
            try {
                foreach ($item in @(Get-ItemProperty -Path $rules.VersionRegistry.Path -ErrorAction SilentlyContinue)) {
                    $display = [string]$item.DisplayName
                    if ($rules.VersionRegistry.NameMatch -and $display -notmatch $rules.VersionRegistry.NameMatch) { continue }
                    $ver = [string]$item.($rules.VersionRegistry.Value)
                    if ([string]::IsNullOrWhiteSpace($ver)) { continue }
                    # 只在登记项指向的正是本次这个安装目录时才采用，避免读到“另一个安装”的版本号
                    $loc = [string]$item.InstallLocation
                    if (-not [string]::IsNullOrWhiteSpace($loc) -and -not [string]::IsNullOrWhiteSpace($Spec.Target)) {
                        if ($loc.TrimEnd('\') -ine $Spec.Target.TrimEnd('\')) { continue }
                    }
                    return $ver.Trim()
                }
            } catch { }
        }
        return ''
    }
    try {
        $r = Invoke-Process -FilePath $exe -Arguments $cmdArgs -TimeoutSeconds 30 -AllowFailure
        $text = ($r.StdOut + ' ' + $r.StdErr).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return '' }
        $first = @($text -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[0]
        if ($first.Length -gt 80) { $first = $first.Substring(0, 80) }
        return $first.Trim()
    } catch {
        return ''
    }
}

# ---------------------------------------------------------------------------
# 动态版本解析（JDK / IDE / Redis）
# ---------------------------------------------------------------------------
function Resolve-DynamicVersions {
    param([hashtable]$Config)
    $resolved = @{}
    $cacheFile = Join-Path $script:Ctx.Cache 'versions.json'
    $cache = @{}
    if (Test-Path -LiteralPath $cacheFile) {
        try { $cache = Read-JsonFile -Path $cacheFile } catch { $cache = @{} }
    }
    $offline = ($script:Options -and $script:Options.Offline)

    # ---------------- JDK （Adoptium） ----------------
    $jdk = Get-ComponentConfig -Name 'jdk'
    if ($jdk.ContainsKey('enabled') -and $jdk.enabled) {
        foreach ($major in @($jdk.versions)) {
            $key = "jdk$major"
            $info = @{ Version = 'latest'; Urls = @(); FileName = "jdk-$major.zip"; Size = 0; ReleaseName = '' }
            if (-not $offline) {
                $api = Format-ComponentTemplate -Template ([string]$jdk.assetsApi) -Values @{ major = $major }
                try {
                    Write-Debug2 "解析 JDK $major 最新版本: $api"
                    $json = Get-RestJson -Url $api
                    $first = @($json)[0]
                    $binary = Get-ObjectProperty -Object $first -Name 'binary'
                    $pkg = Get-ObjectProperty -Object $binary -Name 'package'
                    if ($pkg) {
                        $link = [string](Get-ObjectProperty -Object $pkg -Name 'link')
                        if (-not [string]::IsNullOrWhiteSpace($link)) {
                            $info.Urls = @($link)
                            $info.FileName = [string](Get-ObjectProperty -Object $pkg -Name 'name')
                            $sizeVal = Get-ObjectProperty -Object $pkg -Name 'size'
                            if ($sizeVal) { $info.Size = [long]$sizeVal }
                        }
                    }
                    $ver = Get-ObjectProperty -Object $first -Name 'version'
                    $semver = [string](Get-ObjectProperty -Object $ver -Name 'semver')
                    if ($semver) { $info.Version = $semver }
                    $info.ReleaseName = [string](Get-ObjectProperty -Object $first -Name 'release_name')
                } catch {
                    Write-Warn "获取 JDK $major 版本信息失败: $($_.Exception.Message)"
                }
            }
            if ($info.Urls.Count -eq 0 -and $cache.ContainsKey($key)) {
                Write-Info "使用缓存的 JDK $major 版本信息"
                $cachedInfo = $cache[$key]
                if ($cachedInfo.Urls -and @($cachedInfo.Urls).Count -gt 0) { $info = $cachedInfo }
            }
            if ($info.Urls.Count -eq 0) {
                # 兜底：Adoptium 二进制直链（会自动重定向到具体版本）
                $info.Urls = @("https://api.adoptium.net/v3/binary/latest/$major/ga/windows/x64/jdk/hotspot/normal/eclipse?project=jdk")
                $info.FileName = "jdk-$major.zip"
                if ($info.Version -eq 'latest') { $info.Version = "$major-latest" }
            }
            $resolved[$key] = $info
        }
    }

    # ---------------- IDE （JetBrains） ----------------
    $ide = Get-ComponentConfig -Name 'ide'
    if ($ide.ContainsKey('enabled') -and $ide.enabled) {
        $edition = [string]$ide.edition
        if ([string]::IsNullOrWhiteSpace($edition)) { $edition = 'IC' }
        # 注意：JetBrains 接口用的产品代码与下载文件名前缀不一样：
        #   Community(IC) -> IIC，Ultimate(IU) -> IIU
        # 传错代码时接口仍返回 200，但 JSON 里没有对应字段，会导致“静默解析失败”。
        $apiCode = [string](Get-ObjectProperty -Object $ide -Name 'releaseCode' -Default '')
        if ([string]::IsNullOrWhiteSpace($apiCode)) {
            if ($edition -ieq 'IC') { $apiCode = 'IIC' }
            elseif ($edition -ieq 'IU') { $apiCode = 'IIU' }
            else { $apiCode = $edition }
        }
        $wanted = [string]$ide.version
        $info = @{ Version = $wanted; Urls = @(); FileName = ''; Size = 0; Source = '' }
        if ($wanted -eq 'latest' -and -not $offline) {
            $api = Format-ComponentTemplate -Template ([string]$ide.releaseApi) -Values @{ code = $apiCode }
            try {
                Write-Debug2 "解析 IDE 最新版本: $api"
                $json = Get-RestJson -Url $api
                $release = @(Get-ObjectProperty -Object $json -Name $apiCode)[0]
                if (-not $release) {
                    $keys = @($json.PSObject.Properties | ForEach-Object { $_.Name })
                    Write-Warn "JetBrains 接口返回里没有 '$apiCode' 字段（顶层字段: $($keys -join ', ')），请检查 components.ide.edition/releaseCode"
                }
                if ($release) {
                    $zip = Get-ObjectProperty -Object (Get-ObjectProperty -Object $release -Name 'downloads') -Name 'windowsZip'
                    $link = [string](Get-ObjectProperty -Object $zip -Name 'link')
                    if (-not [string]::IsNullOrWhiteSpace($link)) {
                        $info.Urls = @($link)
                        $info.FileName = Split-Path -Leaf $link
                        $sizeVal = Get-ObjectProperty -Object $zip -Name 'size'
                        if ($sizeVal) { $info.Size = [long]$sizeVal }
                        $info.Source = 'official-api'
                    }
                    $ver = [string](Get-ObjectProperty -Object $release -Name 'version')
                    if ($ver) { $info.Version = $ver }
                }
            } catch {
                Write-Warn "获取 IntelliJ IDEA 最新版本失败（将改用发布列表/缓存兜底）: $($_.Exception.Message)"
            }
        }
        # 兜底 1：latest 接口不可用时，改用“完整发布列表”，取最新的、链接可用的正式版本
        # （比直接跳到配置里写死的 fallbackVersion 靠谱：拿到的是真实版本号和真实文件大小）
        if ($info.Urls.Count -eq 0 -and $wanted -eq 'latest' -and -not $offline) {
            try {
                $listApi = (Format-ComponentTemplate -Template ([string]$ide.releaseApi) -Values @{ code = $apiCode }) -replace '&latest=true', ''
                Write-Debug2 "改用发布列表解析 IDE 版本: $listApi"
                $all = Get-RestJson -Url $listApi
                $tried = 0
                foreach ($rel in @(Get-ObjectProperty -Object $all -Name $apiCode)) {
                    $zip = Get-ObjectProperty -Object (Get-ObjectProperty -Object $rel -Name 'downloads') -Name 'windowsZip'
                    $link = [string](Get-ObjectProperty -Object $zip -Name 'link')
                    if ([string]::IsNullOrWhiteSpace($link)) { continue }
                    $tried++
                    if ($tried -gt 5) { break }
                    if ((Test-RemoteUrl -Url $link -TimeoutSeconds 15).Ok) {
                        $info.Urls = @($link)
                        $info.FileName = Split-Path -Leaf $link
                        $sizeVal = Get-ObjectProperty -Object $zip -Name 'size'
                        if ($sizeVal) { $info.Size = [long]$sizeVal }
                        $ver = [string](Get-ObjectProperty -Object $rel -Name 'version')
                        if ($ver) { $info.Version = $ver }
                        $info.Source = 'release-list'
                        break
                    }
                }
            } catch {
                Write-Debug2 "获取 IDE 发布列表失败: $($_.Exception.Message)"
            }
        }
        if ($info.Urls.Count -eq 0 -and $cache.ContainsKey('ide') -and $wanted -eq 'latest') {
            $cachedIde = $cache['ide']
            if ($cachedIde.Urls -and @($cachedIde.Urls).Count -gt 0) {
                Write-Info "使用缓存的 IDE 版本信息（$($cachedIde.Version)）"
                $info = $cachedIde
                $info.Source = 'cache'
            }
        }
        if ($info.Urls.Count -eq 0) {
            if ($wanted -eq 'latest') {
                $fallback = [string](Get-ObjectProperty -Object $ide -Name 'fallbackVersion' -Default '')
                if (-not [string]::IsNullOrWhiteSpace($fallback)) {
                    Write-Warn "接口、发布列表与缓存都不可用，改用配置中的 fallbackVersion=$fallback"
                    $info.Version = $fallback
                    $info.Urls = Expand-TemplateList -Templates $ide.urlTemplates -Values @{ version = $fallback }
                    $info.Source = 'fallback-version'
                } else {
                    Write-Warn '无法解析 IDE 最新版本，请在配置中写死 ide.version 或设置 ide.fallbackVersion'
                    $info.Version = 'latest'
                    $info.Source = 'fallback-version'
                }
            } else {
                $info.Urls = Expand-TemplateList -Templates $ide.urlTemplates -Values @{ version = $wanted }
                $info.Version = $wanted
                $info.Source = 'pinned'
            }
        }

        # ---- 组装候选地址：API 直链 + 命名模板 + 备用 CDN 主机（download-cdn）----
        $ver = [string]$info.Version
        $raw = New-Object Collections.ArrayList
        foreach ($u in @($info.Urls)) { if (-not [string]::IsNullOrWhiteSpace([string]$u)) { [void]$raw.Add([string]$u) } }
        if ($ver -and $ver -ne 'latest') {
            foreach ($u in (Expand-TemplateList -Templates $ide.urlTemplates -Values @{ version = $ver })) { [void]$raw.Add($u) }
        }
        foreach ($u in @($raw)) {
            if ($u -like 'https://download.jetbrains.com/*') {
                [void]$raw.Add(($u -replace '^https://download\.jetbrains\.com/', 'https://download-cdn.jetbrains.com/'))
            }
        }
        $primary = New-Object Collections.ArrayList
        foreach ($u in @($raw)) {
            if (-not [string]::IsNullOrWhiteSpace($u) -and -not $primary.Contains($u)) { [void]$primary.Add($u) }
        }

        # 探测主候选，只要有一个可用就照常走；全不可用才回退到“最近的几个正式版本”
        $anyPrimary = $false
        if (-not $offline) {
            foreach ($u in @($primary)) {
                if ((Test-RemoteUrl -Url $u -TimeoutSeconds 15).Ok) { $anyPrimary = $true; break }
            }
        } else {
            $anyPrimary = $true
        }

        if (-not $anyPrimary) {
            $recentCount = [int](Get-ObjectProperty -Object $ide -Name 'recentFallbackCount' -Default 0)
            if ($recentCount -gt 0) {
                Write-Warn "版本 $ver 的下载地址当前不可用，尝试回退到最近的正式版本..."
                try {
                    $listApi = (Format-ComponentTemplate -Template ([string]$ide.releaseApi) -Values @{ code = $apiCode }) -replace '&latest=true', ''
                    $all = Get-RestJson -Url $listApi
                    foreach ($rel in @(Get-ObjectProperty -Object $all -Name $apiCode | Select-Object -First $recentCount)) {
                        $zip = Get-ObjectProperty -Object (Get-ObjectProperty -Object $rel -Name 'downloads') -Name 'windowsZip'
                        $link = [string](Get-ObjectProperty -Object $zip -Name 'link')
                        if ([string]::IsNullOrWhiteSpace($link)) { continue }
                        $relVer = [string](Get-ObjectProperty -Object $rel -Name 'version')
                        Write-Warn "  回退候选: $relVer -> $link"
                        if (-not $primary.Contains($link)) { [void]$primary.Add($link) }
                        $cdn = $link -replace '^https://download\.jetbrains\.com/', 'https://download-cdn.jetbrains.com/'
                        if (-not $primary.Contains($cdn)) { [void]$primary.Add($cdn) }
                    }
                    # 候选里可能混有别的版本，大小校验不再适用（完整性仍由 Content-Length 保证）
                    $info.Size = 0
                } catch {
                    Write-Warn "获取 IDE 历史版本列表失败: $($_.Exception.Message)"
                }
            }
        }
        $info.Urls = $primary.ToArray()

        # 说明版本是从哪儿来的，方便排查（官方接口 / 发布列表 / 本地缓存 / 配置指定）
        $sourceText = '配置指定'
        switch ([string]$info.Source) {
            'official-api' { $sourceText = 'JetBrains 官方接口' }
            'release-list' { $sourceText = 'JetBrains 发布列表' }
            'cache' { $sourceText = '本地缓存 versions.json' }
            'fallback-version' { $sourceText = '配置的 fallbackVersion' }
        }
        $sizeText = ''
        if ($info.Size -gt 0) { $sizeText = '，大小 ' + (Format-FileSize -Bytes $info.Size) }
        Write-Info ("IDE 版本: {0}（来源: {1}，候选地址 {2} 个{3}）" -f $info.Version, $sourceText, @($info.Urls).Count, $sizeText)
        $resolved['ide'] = $info
    }

    # ---------------- Redis （GitHub Release） ----------------
    $redis = Get-ComponentConfig -Name 'redis'
    if ($redis.ContainsKey('enabled') -and $redis.enabled) {
        $ver = [string]$redis.version
        $info = @{ Version = $ver; Urls = @(); FileName = ''; Size = 0 }
        if ($ver -eq 'latest' -and -not $offline) {
            try {
                $api = "https://api.github.com/repos/$($redis.githubRepo)/releases/latest"
                Write-Debug2 "解析 Redis 最新版本: $api"
                $rel = Get-RestJson -Url $api
                $tag = [string](Get-ObjectProperty -Object $rel -Name 'tag_name')
                if ($tag) { $ver = $tag.TrimStart('v') }
            } catch {
                Write-Warn "获取 Redis 版本信息失败: $($_.Exception.Message)"
            }
        }
        if ($ver -eq 'latest' -and $cache.ContainsKey('redis')) {
            $cachedRedis = $cache['redis']
            if ($cachedRedis.Version -and $cachedRedis.Version -ne 'latest') {
                Write-Info "使用缓存的 Redis 版本信息（$($cachedRedis.Version)）"
                $ver = $cachedRedis.Version
            }
        }
        $asset = Format-ComponentTemplate -Template ([string]$redis.assetPattern) -Values @{ version = $ver }
        $tagValue = "$($redis.tagPrefix)$ver"
        $urls = Expand-TemplateList -Templates $redis.urlTemplates -Values @{ repo = $redis.githubRepo; tag = $tagValue; asset = $asset; version = $ver }
        $info.Version = $ver
        $info.FileName = $asset
        $info.Urls = $urls
        $info.MirrorUrls = Expand-TemplateList -Templates $redis.mirrorTemplates -Values @{ repo = $redis.githubRepo; tag = $tagValue; asset = $asset; version = $ver }
        $resolved['redis'] = $info
    }

    # ---------------- dsh 桌面端 （官方更新清单） ----------------
    $dsh = Get-ComponentConfig -Name 'dsh'
    if ($dsh.ContainsKey('enabled') -and $dsh.enabled) {
        $ver = [string]$dsh.version
        $usedFallback = $false
        $info = @{ Version = $ver; Urls = @(); FileName = ''; Size = 0; Source = 'config' }
        $feedUrl = [string]$dsh.feedUrl
        if ($ver -eq 'latest' -and -not $offline -and -not [string]::IsNullOrWhiteSpace($feedUrl)) {
            try {
                Write-Debug2 "解析 dsh 桌面端最新版本: $feedUrl"
                $text = Get-RestText -Url $feedUrl
                # 清单是 electron-updater 的 YAML（version / files[0].url / size / path），
                # 这里只要三个字段，用最小正则解析即可，不引入 YAML 依赖
                $mV = [regex]::Match($text, "(?m)^\s*version:\s*'?([0-9][^\s']*)")
                $mU = [regex]::Match($text, "https?://[^\s'""]*win-x64\.exe")
                $mS = [regex]::Match($text, '(?m)^\s*size:\s*(\d+)')
                if ($mV.Success) { $ver = $mV.Groups[1].Value.Trim() }
                if ($mU.Success) { $info.Urls = @($mU.Value) }
                if ($mS.Success) { $info.Size = [long]$mS.Groups[1].Value }
                if ($mV.Success -or $mU.Success) { $info.Source = 'official-feed' }
            } catch {
                Write-Warn "获取 dsh 桌面端版本信息失败: $($_.Exception.Message)"
            }
        }
        # 只有“需要远程解析最新版”时才看缓存；版本号是配置里写死的，就直接用配置里的地址，
        # 免得历史缓存把来源说成“本地缓存”而让人误会
        if ($ver -eq 'latest' -and @($info.Urls).Count -eq 0 -and $cache.ContainsKey('dsh')) {
            $cachedDsh = $cache['dsh']
            if ($cachedDsh.Urls -and @($cachedDsh.Urls).Count -gt 0) {
                Write-Info "使用缓存的 dsh 桌面端版本信息（$($cachedDsh.Version)）"
                $info = $cachedDsh
                $ver = [string]$cachedDsh.Version
                $info.Source = 'cache'
            }
        }
        if ($ver -eq 'latest') {
            $ver = [string]$dsh.fallbackVersion
            if ([string]::IsNullOrWhiteSpace($ver)) { $ver = '0.2.0-rc.2' }
            $usedFallback = $true
            $info.Source = 'fallback-version'
        }
        if (@($info.Urls).Count -eq 0) {
            $info.Urls = Expand-TemplateList -Templates $dsh.urlTemplates -Values @{ version = $ver }
            # 版本号是配置里写死的（不是 latest 兜底）时，保持“配置指定”，不要误报成 fallbackVersion
            if ($usedFallback) { $info.Source = 'fallback-version' }
        }
        $info.Version = $ver
        $url0 = ''
        if (@($info.Urls).Count -gt 0) { $url0 = [string]@($info.Urls)[0] }
        if (-not [string]::IsNullOrWhiteSpace($url0)) {
            $mFile = [regex]::Match($url0, '/([^/]+\.exe)(\?|$)')
            if ($mFile.Success) { $info.FileName = $mFile.Groups[1].Value }
        }
        if ([string]::IsNullOrWhiteSpace([string]$info.FileName)) { $info.FileName = "deepseek-harness-$ver-win-x64.exe" }

        $srcText = '配置指定'
        switch ([string]$info.Source) {
            'official-feed' { $srcText = '官方更新清单 nightly.yml' }
            'cache' { $srcText = '本地缓存 versions.json' }
            'fallback-version' { $srcText = '配置的 fallbackVersion' }
        }
        $sizeText = ''
        if ([long]$info.Size -gt 0) { $sizeText = '，大小 ' + (Format-FileSize -Bytes ([long]$info.Size)) }
        Write-Info ("dsh 桌面端版本: {0}（来源: {1}{2}）" -f $info.Version, $srcText, $sizeText)
        $resolved['dsh'] = $info
    }

    # 写回缓存
    if (-not $offline -and -not ($script:Options -and $script:Options.DryRun)) {
        try {
            $json = $resolved | ConvertTo-Json -Depth 8
            [IO.File]::WriteAllText($cacheFile, $json, (New-Object Text.UTF8Encoding $false))
        } catch { }
    }
    return $resolved
}

# ---------------------------------------------------------------------------
# 组件条目构造
# ---------------------------------------------------------------------------
function New-ComponentSpec {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Kind = 'archive',
        [hashtable]$Comp = @{},
        [hashtable]$Values = @{},
        [string]$DefaultDir = '',
        [string]$Probe = '',
        [string[]]$PathEntries = @(),
        [hashtable]$EnvVars = @{},
        [string]$Configure = '',
        [string]$DetectKey = '',
        [switch]$AddToPath,
        [string]$Requires = '',
        [string]$Version = '',
        [string]$Group = ''
    )
    $dir = $DefaultDir
    $tpl = ''
    if ($Comp -and $Comp.ContainsKey('dirTemplate')) { $tpl = [string]$Comp.dirTemplate }
    if (-not [string]::IsNullOrWhiteSpace($tpl)) { $dir = Format-ComponentTemplate -Template $tpl -Values $Values }
    $target = Join-Path $script:Ctx.Root $dir
    return @{
        Key         = $Key
        Name        = $Name
        Group       = $Group
        Kind        = $Kind
        Comp        = $Comp
        Values      = $Values
        Version     = $Version
        DirName     = $dir
        Target      = $target
        Probe       = $Probe
        ProbePath   = ''
        PathEntries = @($PathEntries)
        EnvVars     = $EnvVars
        Configure   = $Configure
        DetectKey   = $DetectKey
        AddToPath   = [bool]$AddToPath
        Requires    = $Requires
        Urls        = @()
        MirrorUrls  = @()
        FileName    = ''
        Size        = 0
        Shortcuts   = @()
        Adopted     = $false
        Status      = 'pending'
        Note        = ''
    }
}

function Get-ComponentCatalog {
    param([hashtable]$Config, [hashtable]$Resolved)
    $root = $script:Ctx.Root
    $catalog = New-Object Collections.ArrayList

    # ---------------- JDK ----------------
    $jdkCfg = Get-ComponentConfig -Name 'jdk'
    if ($jdkCfg.enabled) {
        $defaultMajor = [int]$jdkCfg.default
        foreach ($major in @($jdkCfg.versions)) {
            $majorInt = [int]$major
            $key = "jdk$majorInt"
            $info = $null
            if ($Resolved.ContainsKey($key)) { $info = $Resolved[$key] }
            $version = 'latest'
            $urls = @()
            $mirrorUrls = @()
            $fileName = "jdk-$majorInt.zip"
            $size = 0
            if ($info) {
                $version = [string]$info.Version
                $urls = @($info.Urls)
                $fileName = [string]$info.FileName
                if ($info.Size) { $size = [long]$info.Size }
                $mirrorUrls = Expand-TemplateList -Templates $jdkCfg.mirrorTemplates -Values @{ major = $majorInt; fileName = $fileName; version = $version }
            }
            $envVars = @{ "JAVA_HOME_$majorInt" = '.' }
            $spec = New-ComponentSpec -Key $key -Name "JDK $majorInt（Temurin）" -Kind 'archive' -Comp $jdkCfg `
                -Values @{ major = $majorInt; version = $version } -DefaultDir "jdk-$majorInt" `
                -Probe 'bin\java.exe' -PathEntries @('bin') -EnvVars $envVars -DetectKey 'jdk' -AddToPath -Group 'jdk'
            $spec.Version = $version
            $spec.Urls = $urls
            $spec.MirrorUrls = $mirrorUrls
            $spec.FileName = $fileName
            $spec.Size = $size
            $spec.IsDefaultJdk = ($majorInt -eq $defaultMajor)
            if ($spec.IsDefaultJdk) { $spec.EnvVars = @{ 'JAVA_HOME' = '.'; "JAVA_HOME_$majorInt" = '.' } }
            [void]$catalog.Add($spec)
        }
    }

    # ---------------- Maven ----------------
    $mavenCfg = Get-ComponentConfig -Name 'maven'
    if ($mavenCfg.enabled) {
        $ver = [string]$mavenCfg.version
        $spec = New-ComponentSpec -Key 'maven' -Name "Apache Maven $ver" -Kind 'archive' -Comp $mavenCfg `
            -Values @{ version = $ver } -DefaultDir "apache-maven-$ver" `
            -Probe 'bin\mvn.cmd' -PathEntries @('bin') -EnvVars @{ 'MAVEN_HOME' = '.' } `
            -Configure 'Configure-Maven' -DetectKey 'maven' -AddToPath -Group 'build'
        $spec.Version = $ver
        $spec.Urls = Expand-TemplateList -Templates $mavenCfg.urlTemplates -Values @{ version = $ver }
        $spec.FileName = "apache-maven-$ver-bin.zip"
        [void]$catalog.Add($spec)
    }

    # ---------------- Git ----------------
    $gitCfg = Get-ComponentConfig -Name 'git'
    if ($gitCfg.enabled) {
        $ver = [string]$gitCfg.version
        $spec = New-ComponentSpec -Key 'git' -Name "Git $ver（MinGit）" -Kind 'archive' -Comp $gitCfg `
            -Values @{ version = $ver } -DefaultDir "git-$ver" `
            -Probe 'cmd\git.exe' -PathEntries @('cmd') -DetectKey 'git' -AddToPath -Group 'base'
        $spec.Version = $ver
        $spec.Urls = Expand-TemplateList -Templates $gitCfg.urlTemplates -Values @{ version = $ver }
        $spec.FileName = "MinGit-$ver-64-bit.zip"
        [void]$catalog.Add($spec)
    }

    # ---------------- Node ----------------
    $nodeCfg = Get-ComponentConfig -Name 'node'
    if ($nodeCfg.enabled) {
        $ver = [string]$nodeCfg.version
        $spec = New-ComponentSpec -Key 'node' -Name "Node.js $ver" -Kind 'archive' -Comp $nodeCfg `
            -Values @{ version = $ver } -DefaultDir "node-$ver" `
            -Probe 'node.exe' -PathEntries @('.') -Configure 'Configure-Node' -DetectKey 'node' -AddToPath -Group 'base'
        $spec.Version = $ver
        $spec.Urls = Expand-TemplateList -Templates $nodeCfg.urlTemplates -Values @{ version = $ver }
        $spec.FileName = "node-v$ver-win-x64.zip"
        [void]$catalog.Add($spec)
    }

    # ---------------- dsh 桌面端 ----------------
    $dshCfg = Get-ComponentConfig -Name 'dsh'
    if ($dshCfg.enabled) {
        $ver = [string]$dshCfg.version
        $urls = @()
        $fileName = ''
        $size = 0
        if ($Resolved.ContainsKey('dsh')) {
            $ver = [string]$Resolved['dsh'].Version
            $urls = @($Resolved['dsh'].Urls)
            $fileName = [string]$Resolved['dsh'].FileName
            if ($Resolved['dsh'].Size) { $size = [long]$Resolved['dsh'].Size }
        }
        $dirName = 'dsh-desktop'
        if (-not [string]::IsNullOrWhiteSpace([string]$dshCfg.dirTemplate)) { $dirName = [string]$dshCfg.dirTemplate }
        $spec = New-ComponentSpec -Key 'dsh' -Name "DSH 桌面端 $ver" -Kind 'installer' -Comp $dshCfg `
            -Values @{ version = $ver } -DefaultDir $dirName `
            -Probe 'DeepSeek Harness.exe' -Configure 'Configure-Dsh' -DetectKey 'dsh' -Group 'dsh'
        $spec.Version = $ver
        $spec.Urls = $urls
        $spec.FileName = $fileName
        $spec.Size = $size
        [void]$catalog.Add($spec)
    }

    # ---------------- dsh 命令行（npm 全局包，默认关闭） ----------------
    $dshCliCfg = Get-ComponentConfig -Name 'dsh-cli'
    if ($dshCliCfg.ContainsKey('enabled') -and $dshCliCfg.enabled) {
        $prefix = [string]$dshCliCfg.globalPrefix
        if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = 'node-global' }
        $spec = New-ComponentSpec -Key 'dsh-cli' -Name "dsh 命令行（$($dshCliCfg.package)）" -Kind 'npm' -Comp $dshCliCfg `
            -Values @{} -DefaultDir $prefix `
            -Probe 'dsh.cmd' -PathEntries @('.') -Configure 'Configure-DshCli' -DetectKey 'dsh-cli' `
            -AddToPath -Requires 'node' -Group 'dsh'
        $spec.Version = [string]$dshCliCfg.version
        [void]$catalog.Add($spec)
    }

    # ---------------- IntelliJ IDEA ----------------
    $ideCfg = Get-ComponentConfig -Name 'ide'
    if ($ideCfg.enabled) {
        $edition = [string]$ideCfg.edition
        if ([string]::IsNullOrWhiteSpace($edition)) { $edition = 'IC' }
        $version = [string]$ideCfg.version
        $urls = @()
        $size = 0
        $fileName = ''
        if ($Resolved.ContainsKey('ide')) {
            $version = [string]$Resolved['ide'].Version
            $urls = @($Resolved['ide'].Urls)
            $fileName = [string]$Resolved['ide'].FileName
            if ($Resolved['ide'].Size) { $size = [long]$Resolved['ide'].Size }
        }
        $editionName = 'Community'
        if ($edition -eq 'IU') { $editionName = 'Ultimate' }
        $spec = New-ComponentSpec -Key 'ide' -Name "IntelliJ IDEA $editionName $version" -Kind 'archive' -Comp $ideCfg `
            -Values @{ version = $version; edition = $edition } -DefaultDir "idea-$version" `
            -Probe 'bin\idea64.exe' -Configure 'Configure-Ide' -DetectKey 'ide' -Group 'ide'
        $spec.Version = $version
        $spec.Urls = $urls
        $spec.FileName = $fileName
        $spec.Size = $size
        $spec.Edition = $edition
        if ($fileName -eq '') { $spec.FileName = "idea-$version.win.zip" }
        [void]$catalog.Add($spec)
    }

    # ---------------- PostgreSQL ----------------
    $pgCfg = Get-ComponentConfig -Name 'postgres'
    if ($pgCfg.enabled) {
        $ver = [string]$pgCfg.version
        $build = [string]$pgCfg.build
        $spec = New-ComponentSpec -Key 'postgres' -Name "PostgreSQL $ver" -Kind 'archive' -Comp $pgCfg `
            -Values @{ version = $ver; build = $build } -DefaultDir "pgsql-$ver" `
            -Probe 'bin\pg_ctl.exe' -PathEntries @('bin') -Configure 'Configure-Postgres' -DetectKey 'postgres' -AddToPath -Group 'database'
        $spec.Version = $ver
        $spec.Urls = Expand-TemplateList -Templates $pgCfg.urlTemplates -Values @{ version = $ver; build = $build }
        $spec.FileName = "postgresql-$ver-$build-windows-x64-binaries.zip"
        [void]$catalog.Add($spec)
    }

    # ---------------- Redis ----------------
    $redisCfg = Get-ComponentConfig -Name 'redis'
    if ($redisCfg.enabled) {
        $ver = [string]$redisCfg.version
        $urls = @()
        $mirrorUrls = @()
        $fileName = ''
        if ($Resolved.ContainsKey('redis')) {
            $ver = [string]$Resolved['redis'].Version
            $urls = @($Resolved['redis'].Urls)
            $fileName = [string]$Resolved['redis'].FileName
            if ($Resolved['redis'].MirrorUrls) { $mirrorUrls = @($Resolved['redis'].MirrorUrls) }
        }
        $spec = New-ComponentSpec -Key 'redis' -Name "Redis $ver（Windows）" -Kind 'archive' -Comp $redisCfg `
            -Values @{ version = $ver } -DefaultDir "redis-$ver" `
            -Probe 'redis-server.exe' -PathEntries @('.') -Configure 'Configure-Redis' -DetectKey 'redis' -AddToPath -Group 'database'
        $spec.Version = $ver
        $spec.Urls = $urls
        $spec.MirrorUrls = $mirrorUrls
        $spec.FileName = $fileName
        [void]$catalog.Add($spec)
    }

    # ---------------- DBeaver ----------------
    $dbeaverCfg = Get-ComponentConfig -Name 'dbeaver'
    if ($dbeaverCfg.enabled) {
        $ver = [string]$dbeaverCfg.version
        $spec = New-ComponentSpec -Key 'dbeaver' -Name 'DBeaver CE' -Kind 'archive' -Comp $dbeaverCfg `
            -Values @{} -DefaultDir 'dbeaver' `
            -Probe 'dbeaver.exe' -Configure 'Configure-Dbeaver' -DetectKey 'dbeaver' -Group 'dbtool'
        $spec.Version = $ver
        if ($ver -eq 'latest') {
            $spec.Urls = @($dbeaverCfg.urlTemplates[0])
        } else {
            $spec.Urls = Expand-TemplateList -Templates $dbeaverCfg.urlTemplates -Values @{ version = $ver }
        }
        $spec.FileName = 'dbeaver-ce-win32.win32.x86_64.zip'
        [void]$catalog.Add($spec)
    }

    # ---------------- HeidiSQL ----------------
    $heidiCfg = Get-ComponentConfig -Name 'heidisql'
    if ($heidiCfg.enabled) {
        $ver = [string]$heidiCfg.version
        $spec = New-ComponentSpec -Key 'heidisql' -Name "HeidiSQL $ver" -Kind 'archive' -Comp $heidiCfg `
            -Values @{ version = $ver } -DefaultDir "heidisql-$ver" `
            -Probe 'heidisql.exe' -Configure 'Configure-HeidiSql' -DetectKey 'heidisql' -Group 'dbtool'
        $spec.Version = $ver
        $spec.Urls = Expand-TemplateList -Templates $heidiCfg.urlTemplates -Values @{ version = $ver }
        $spec.FileName = "HeidiSQL_${ver}_64_Portable.zip"
        [void]$catalog.Add($spec)
    }

    # ---------------- 自定义 extras ----------------
    foreach ($extra in @(Get-ConfigValue -Path 'components.extras' -Default @())) {
        if (-not $extra) { continue }
        if (-not [bool](Get-ObjectProperty -Object $extra -Name 'enabled' -Default $true)) { continue }
        $extraKey = [string](Get-ObjectProperty -Object $extra -Name 'key')
        if ([string]::IsNullOrWhiteSpace($extraKey)) { continue }
        $extraName = [string](Get-ObjectProperty -Object $extra -Name 'name')
        if ([string]::IsNullOrWhiteSpace($extraName)) { $extraName = $extraKey }
        $dirName = [string](Get-ObjectProperty -Object $extra -Name 'dirName')
        if ([string]::IsNullOrWhiteSpace($dirName)) { $dirName = $extraKey }
        $probe = [string](Get-ObjectProperty -Object $extra -Name 'exe')
        $pathEntries = @((Get-ObjectProperty -Object $extra -Name 'pathEntries' -Default @()))
        $addToPath = [bool](Get-ObjectProperty -Object $extra -Name 'addToPath' -Default $false)

        $urls = @()
        $tpls = Get-ObjectProperty -Object $extra -Name 'urlTemplates'
        if ($tpls) { $urls = @($tpls) } else {
            $single = [string](Get-ObjectProperty -Object $extra -Name 'url')
            if ($single) { $urls = @($single) }
        }
        $spec = New-ComponentSpec -Key $extraKey -Name $extraName -Kind 'archive' -Comp @{ dirTemplate = $dirName } `
            -Values @{} -DefaultDir $dirName -Probe $probe -PathEntries $pathEntries -AddToPath:$addToPath -Group 'extra'
        $spec.Urls = Expand-TemplateList -Templates $urls -Values @{}
        $spec.FileName = [string](Get-ObjectProperty -Object $extra -Name 'fileName')
        if ([string]::IsNullOrWhiteSpace($spec.FileName)) {
            if ($spec.Urls.Count -gt 0) { $spec.FileName = Split-Path -Leaf $spec.Urls[0] } else { $spec.FileName = "$extraKey.zip" }
        }
        $spec.Version = [string](Get-ObjectProperty -Object $extra -Name 'version')
        $shortcutDefs = New-Object Collections.ArrayList
        foreach ($sc in @((Get-ObjectProperty -Object $extra -Name 'shortcuts' -Default @()))) {
            [void]$shortcutDefs.Add(@{
                Item   = $extraKey
                Name   = [string](Get-ObjectProperty -Object $sc -Name 'name')
                Target = [string](Get-ObjectProperty -Object $sc -Name 'target')
                Arguments = [string](Get-ObjectProperty -Object $sc -Name 'arguments' -Default '')
                Icon   = [string](Get-ObjectProperty -Object $sc -Name 'icon' -Default '')
                WindowStyle = 1
            })
        }
        $spec.Shortcuts = $shortcutDefs.ToArray()
        [void]$catalog.Add($spec)
    }

    return $catalog.ToArray()
}

# ---------------------------------------------------------------------------
# 安装引擎
# ---------------------------------------------------------------------------
function Test-ComponentReady {
    param([hashtable]$Spec)
    if ([string]::IsNullOrWhiteSpace($Spec.Probe)) { return (Test-Path -LiteralPath $Spec.Target) }
    $candidate = Join-Path $Spec.Target $Spec.Probe
    if (Test-Path -LiteralPath $candidate) {
        $Spec.ProbePath = $candidate
        return $true
    }
    # 兼容不同的压缩包层级
    $found = Find-FileIn -Root $Spec.Target -Name (Split-Path -Leaf $Spec.Probe) -MaxDepth 2
    if ($found) {
        $Spec.ProbePath = $found
        return $true
    }
    return $false
}

function Get-ComponentDownloadUrls {
    param([hashtable]$Spec)
    $official = @($Spec.Urls)
    $mirrors = @($Spec.MirrorUrls)
    if ($official.Count -eq 0) { return $mirrors }
    if ($mirrors.Count -eq 0) { return $official }
    if (Test-PreferMirrors) {
        return (@($mirrors) + @($official))
    }
    return (@($official) + @($mirrors))
}

function Install-ArchiveComponent {
    param([Parameter(Mandatory = $true)][hashtable]$Spec)
    $urls = Get-ComponentDownloadUrls -Spec $Spec
    if ($urls.Count -eq 0) { throw "组件 $($Spec.Key) 没有可用的下载地址" }

    $fileName = [string]$Spec.FileName
    if ([string]::IsNullOrWhiteSpace($fileName)) { $fileName = "$($Spec.Key).zip" }
    $fileName = $fileName -replace '[\\/:*?"<>|]', '_'
    $file = Join-Path $script:Ctx.Cache $fileName

    Write-Info "$($Spec.Name) → 下载 $fileName"
    $dl = Get-RemoteFile -Urls $urls -Destination $file -ExpectedSize ([long]$Spec.Size) -Label $Spec.Name -ForceDownload:([bool]$script:Options.Force)

    Write-Info "$($Spec.Name) → 解压到 $($Spec.Target)"
    Expand-ArchiveTo -Archive $file -Destination $Spec.Target -Force:([bool]$script:Options.Force)

    if (-not (Test-ComponentReady -Spec $Spec)) {
        throw "解压后未找到可执行文件 $($Spec.Probe)（$($Spec.Target)）"
    }
    Set-ComponentMarker -Target $Spec.Target -Key $Spec.Key -Version $Spec.Version -Source 'downloaded' -Origin $dl.Url
    if (-not [bool](Get-ConfigValue -Path 'download.keepArchives' -Default $true)) {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function Install-NpmComponent {
    param([Parameter(Mandatory = $true)][hashtable]$Spec)
    $comp = $Spec.Comp
    $nodeSpec = @($script:Catalog | Where-Object { $_.Key -eq 'node' })[0]
    $nodeExe = $null
    $npmCli = $null

    if ($nodeSpec -and (Test-Path -LiteralPath $nodeSpec.Target)) {
        $candidateNode = Join-Path $nodeSpec.Target 'node.exe'
        if (Test-Path -LiteralPath $candidateNode) { $nodeExe = $candidateNode }
        $candidateCli = Join-Path $nodeSpec.Target 'node_modules\npm\bin\npm-cli.js'
        if (Test-Path -LiteralPath $candidateCli) { $npmCli = $candidateCli }
    }
    if (-not $nodeExe) {
        $cmd = Get-Command -Name 'node.exe' -ErrorAction SilentlyContinue
        if ($cmd) {
            $nodeExe = $cmd.Source
            $candidateCli = Join-Path (Split-Path -Parent $nodeExe) 'node_modules\npm\bin\npm-cli.js'
            if (Test-Path -LiteralPath $candidateCli) { $npmCli = $candidateCli }
        }
    }
    if (-not $nodeExe) { throw '找不到 Node.js，无法安装 dsh，请先启用 components.node' }
    if (-not $npmCli) { throw "找不到 npm-cli.js（$nodeExe），无法安装 dsh" }

    $prefix = $Spec.Target
    New-DirectoryFor -Path $prefix -Quiet | Out-Null
    $pkg = [string]$comp.package
    if ([string]::IsNullOrWhiteSpace($pkg)) { $pkg = '@deepseek-ai/dsh' }
    $ver = [string]$comp.version
    if ([string]::IsNullOrWhiteSpace($ver) -or $ver -eq 'latest') { $pkg = $pkg } else { $pkg = "$pkg@$ver" }

    $npmArgs = @($npmCli, 'install', '-g', '--prefix', $prefix, '--no-fund', '--no-audit')
    $registry = [string]$comp.registry
    if (-not [string]::IsNullOrWhiteSpace($registry)) { $npmArgs += @('--registry', $registry) }
    $npmArgs += $pkg

    Write-Info "$($Spec.Name) → npm install -g --prefix $prefix $pkg"
    $r = Invoke-Process -FilePath $nodeExe -Arguments $npmArgs -TimeoutSeconds 1800
    if ($r.ExitCode -ne 0) {
        throw "npm 安装失败（退出码 $($r.ExitCode)）: $($r.StdErr)$($r.StdOut)"
    }
    if (-not (Test-ComponentReady -Spec $Spec)) {
        throw "npm 安装完成但未找到 $($Spec.Probe)（$prefix）"
    }
    Set-ComponentMarker -Target $Spec.Target -Key $Spec.Key -Version $ver -Source 'npm' -Origin $registry
}

function Get-UninstallInstallLocation {
    # 从“添加/删除程序”登记里读取安装目录。
    # 用途：NSIS 安装器不一定采纳 /D= 指定的目录，用登记的实际位置兜底定位。
    param([Parameter(Mandatory = $true)][string]$NamePattern)
    $hives = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    foreach ($hive in $hives) {
        foreach ($item in @(Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue)) {
            $name = [string]$item.DisplayName
            if ([string]::IsNullOrWhiteSpace($name) -or $name -notmatch $NamePattern) { continue }
            $loc = [string]$item.InstallLocation
            if (-not [string]::IsNullOrWhiteSpace($loc)) { return $loc.TrimEnd('\') }
        }
    }
    return ''
}

function Test-RunningProcess {
    param([Parameter(Mandatory = $true)][string]$NamePattern)
    try {
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
            if ($p.ProcessName -match $NamePattern) { return $true }
        }
    } catch { }
    return $false
}

function Install-InstallerComponent {
    # 带安装程序（NSIS）的组件：先静默安装，再按“探针文件”确认结果。
    # 之所以要兜底：electron-builder 的 NSIS 安装器不保证采纳 /D=<目录>，
    # 所以安装后如果探针不在预期目录，就去注册表登记的实际目录里找。
    param([Parameter(Mandatory = $true)][hashtable]$Spec)
    $urls = Get-ComponentDownloadUrls -Spec $Spec
    if ($urls.Count -eq 0) { throw "组件 $($Spec.Key) 没有可用的下载地址" }

    $fileName = [string]$Spec.FileName
    if ([string]::IsNullOrWhiteSpace($fileName)) { $fileName = "$($Spec.Key)-setup.exe" }
    $fileName = $fileName -replace '[\\/:*?"<>|]', '_'
    $file = Join-Path $script:Ctx.Cache $fileName

    # 安装器可能强制结束正在运行的实例（会打断用户手头的会话），先挡住
    $procPattern = [string]$Spec.Comp.runningProcess
    if (-not [string]::IsNullOrWhiteSpace($procPattern) -and (Test-RunningProcess -NamePattern $procPattern)) {
        throw ("检测到 $procPattern 正在运行，安装程序可能会强制结束它（会中断你正在进行的会话）。" + [Environment]::NewLine +
            "请先退出该程序再重跑本脚本；或加 -Components 跳过该组件。")
    }

    Write-Info "$($Spec.Name) → 下载 $fileName"
    $dl = Get-RemoteFile -Urls $urls -Destination $file -ExpectedSize ([long]$Spec.Size) -Label $Spec.Name -ForceDownload:([bool]$script:Options.Force)

    # NSIS 参数：/D= 必须是最后一个参数，且不能加引号（所以路径含空格时只能用安装器默认目录）
    $silentList = New-Object Collections.ArrayList
    foreach ($a in @($Spec.Comp.silentArgs)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$a)) { [void]$silentList.Add([string]$a) }
    }
    $dirArg = [string]$Spec.Comp.installDirArg
    if (-not [string]::IsNullOrWhiteSpace($dirArg)) {
        if ($Spec.Target -match '\s') {
            Write-Warn "安装根目录含空格（$($Spec.Target)），NSIS 的 /D= 不支持带空格的路径，将使用安装程序的默认目录"
            Write-Warn "如需装到指定目录，请把 installRoot 改成不含空格的路径（例如 D:\JavaDevEnv）"
        } else {
            [void]$silentList.Add(($dirArg -replace '\{dir\}', $Spec.Target))
        }
    }
    $silentArgs = $silentList.ToArray()
    $shown = ''
    if ($silentArgs.Count -gt 0) { $shown = '（' + ($silentArgs -join ' ') + '）' }
    Write-Info "$($Spec.Name) → 静默安装 $shown"

    $r = Invoke-Process -FilePath $file -Arguments $silentArgs -TimeoutSeconds 1800
    if ($r.TimedOut) { throw "安装程序超时未结束（30 分钟）: $file" }
    if ($r.ExitCode -ne 0) {
        Write-Warn "安装程序退出码 $($r.ExitCode)（继续检查安装结果）"
    }

    if (-not (Test-ComponentReady -Spec $Spec)) {
        $pattern = [string]$Spec.Comp.uninstallNamePattern
        if ([string]::IsNullOrWhiteSpace($pattern)) { $pattern = [IO.Path]::GetFileNameWithoutExtension([string]$Spec.Probe) }
        $loc = Get-UninstallInstallLocation -NamePattern $pattern
        if (-not [string]::IsNullOrWhiteSpace($loc) -and (Test-Path -LiteralPath $loc)) {
            Write-Info "安装程序实际安装到: $loc（未采用 /D= 指定的目录）"
            $Spec.Target = $loc
            [void](Test-ComponentReady -Spec $Spec)
        }
    }

    if (-not (Test-ComponentReady -Spec $Spec)) {
        $msg = New-Object Collections.ArrayList
        [void]$msg.Add("静默安装后没找到 $($Spec.Probe)（预期目录 $($Spec.Target)）")
        [void]$msg.Add('可以手动安装（安装包已经下载好了）：')
        [void]$msg.Add("  双击 $file")
        [void]$msg.Add('安装完成后重跑本脚本即可（existingPolicy=prefer 会自动检测并复用，不会重复下载）')
        throw (($msg) -join [Environment]::NewLine)
    }
    Write-Ok "$($Spec.Name) 已安装到 $($Spec.Target)"
    Set-ComponentMarker -Target $Spec.Target -Key $Spec.Key -Version $Spec.Version -Source 'installer' -Origin $dl.Url
}

function Install-Component {
    param([Parameter(Mandatory = $true)][hashtable]$Spec)
    # 依赖检查
    if ($Spec.Requires) {
        $dep = @($script:Catalog | Where-Object { $_.Key -eq $Spec.Requires })[0]
        if ($dep -and -not (Test-ComponentReady -Spec $dep)) {
            throw "组件 $($Spec.Name) 依赖 $($dep.Name)，请先安装"
        }
    }
    if ($Spec.Kind -eq 'npm') {
        Install-NpmComponent -Spec $Spec
    } elseif ($Spec.Kind -eq 'installer') {
        Install-InstallerComponent -Spec $Spec
    } else {
        Install-ArchiveComponent -Spec $Spec
    }
}

function Set-ComponentEnvironment {
    param([Parameter(Mandatory = $true)][hashtable]$Spec)
    if (-not $Spec.AddToPath -and $Spec.EnvVars.Count -eq 0) { return }
    $setVars = [bool](Get-ConfigValue -Path 'env.setUserEnvVars' -Default $true)
    $setPath = [bool](Get-ConfigValue -Path 'env.updateUserPath' -Default $true)
    $noEnv = ($script:Options -and $script:Options.NoEnv)

    if ($setVars -and -not $noEnv) {
        foreach ($name in @($Spec.EnvVars.Keys)) {
            $rel = [string]$Spec.EnvVars[$name]
            $value = $Spec.Target
            if ($rel -and $rel -ne '.') { $value = Join-Path $Spec.Target $rel }
            $existing = Get-UserEnvRaw -Name $name
            if ($existing.Exists) {
                if ($existing.Value.TrimEnd('\') -ieq $value.TrimEnd('\')) { continue }
                $force = [bool](Get-ConfigValue -Path 'env.forceJavaHome' -Default $false)
                if ($name -eq 'JAVA_HOME' -and -not $force -and $Spec.Adopted) {
                    Write-Warn "JAVA_HOME 已指向 $($existing.Value)，保留原值（如需切换为目标 JDK，请设置 env.forceJavaHome=true）"
                    continue
                }
                if (-not $script:Options.Force -and $Spec.Adopted) {
                    Write-Warn "$name 已存在（$($existing.Value)），保留原值"
                    continue
                }
                Write-Warn "$name 由 $($existing.Value) 改为 $value"
            }
            Set-UserEnvRaw -Name $name -Value $value
            Write-Info "设置用户环境变量 $name = $value"
        }
    }

    if ($setPath -and $Spec.AddToPath -and -not $noEnv) {
        foreach ($rel in @($Spec.PathEntries)) {
            $dir = $Spec.Target
            if ($rel -and $rel -ne '.') { $dir = Join-Path $Spec.Target $rel }
            if (Test-Path -LiteralPath $dir) { [void](Add-UserPathEntry -Entry $dir -Reason $Spec.Name) }
        }
    }
    # 当前进程同步，便于后续组件调用
    foreach ($rel in @($Spec.PathEntries)) {
        $dir = $Spec.Target
        if ($rel -and $rel -ne '.') { $dir = Join-Path $Spec.Target $rel }
        Add-ProcessPath -Directory $dir
    }
}

function Get-CmdKArguments {
    param([Parameter(Mandatory = $true)][string]$ScriptPath, [string]$Extra = '')
    if ($ScriptPath -match '\s') {
        return ('/k ""' + $ScriptPath + '"' + $(if ($Extra) { " $Extra" } else { '' }) + '"')
    }
    return ('/k "' + $ScriptPath + '"' + $(if ($Extra) { " $Extra" } else { '' }))
}

function New-ComponentShortcuts {
    param([Parameter(Mandatory = $true)][hashtable]$Spec)
    if ($script:Options -and $script:Options.NoShortcuts) { return }
    if (-not [bool](Get-ConfigValue -Path 'shortcuts.enabled' -Default $true)) { return }
    $wanted = @(Get-ConfigValue -Path 'shortcuts.items' -Default @())
    $targets = New-Object Collections.ArrayList
    if ([bool](Get-ConfigValue -Path 'shortcuts.desktop' -Default $true)) {
        [void]$targets.Add((Get-ShortcutDirectory -Kind 'Desktop'))
    }
    if ([bool](Get-ConfigValue -Path 'shortcuts.startMenu' -Default $false)) {
        [void]$targets.Add((Get-ShortcutDirectory -Kind 'StartMenu'))
    }
    if ($targets.Count -eq 0) { return }

    foreach ($sc in @($Spec.Shortcuts)) {
        if (-not $sc) { continue }
        $item = [string]$sc.Item
        if ($item -and ($wanted -notcontains $item)) { continue }
        $name = [string]$sc.Name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $lnkTarget = [string]$sc.Target
        if ([string]::IsNullOrWhiteSpace($lnkTarget)) {
            Write-Debug2 "跳过快捷方式 $name（未指定目标）"
            continue
        }
        if (-not [IO.Path]::IsPathRooted($lnkTarget)) {
            $candidate = Join-Path $Spec.Target $lnkTarget
            if (Test-Path -LiteralPath $candidate) { $lnkTarget = $candidate }
        }
        if (-not (Test-Path -LiteralPath $lnkTarget)) {
            Write-Debug2 "跳过快捷方式 $name（目标不存在: $lnkTarget）"
            continue
        }
        $workDir = $Spec.Target
        if (-not (Test-Path -LiteralPath $workDir)) { $workDir = Split-Path -Parent $lnkTarget }
        $windowStyle = 1
        if ($sc.ContainsKey('WindowStyle')) { $windowStyle = [int]$sc.WindowStyle }

        foreach ($dir in $targets) {
            $path = Join-Path $dir ($name + '.lnk')
            [void](New-Shortcut -Path $path -TargetPath $lnkTarget `
                    -Arguments ([string]$sc.Arguments) -WorkingDirectory $workDir `
                    -IconLocation ([string]$sc.Icon) -Description $Spec.Name `
                    -WindowStyle $windowStyle)
        }
    }
}
