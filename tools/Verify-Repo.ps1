<#
    Repository self-check for Java-Dev-Env-Script.

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\Verify-Repo.ps1
        pwsh -NoProfile -File tools\Verify-Repo.ps1
        powershell ... -File tools\Verify-Repo.ps1 -Path C:\some\other\tree

    Why this exists (three rules learned the hard way):
      1. Every .ps1 MUST start with a UTF-8 BOM. Windows PowerShell 5.1 decodes
         BOM-less files as ANSI/GBK, which turns Chinese text into garbage and
         can break parsing entirely ("Missing closing ')' in expression").
      2. Every .cmd MUST NOT have a BOM. cmd.exe treats the BOM as part of the
         first command and fails with a confusing error.
      3. Every .ps1 must actually parse under the interpreter that will run it,
         so CI runs this script under BOTH Windows PowerShell 5.1 and
         PowerShell 7 - only the 5.1 pass catches the BOM problem.

    Exit code: 0 = all checks passed, 1 = at least one error.
#>
[CmdletBinding()]
param(
    # Directory to check. Defaults to the repository root (parent of tools\).
    [string]$Path = ''
)

$ErrorActionPreference = 'Stop'
$script:ErrorCount = 0
$script:WarnCount = 0

function Write-Ok { param([string]$Message) Write-Host "  [ok]   $Message" -ForegroundColor Green }
function Write-Bad { param([string]$Message) $script:ErrorCount++; Write-Host "  [FAIL] $Message" -ForegroundColor Red }
function Write-Soft { param([string]$Message) $script:WarnCount++; Write-Host "  [warn] $Message" -ForegroundColor Yellow }
function Write-Head { param([string]$Message) Write-Host ''; Write-Host "== $Message" -ForegroundColor Cyan }

if ([string]::IsNullOrWhiteSpace($Path)) {
    $here = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($here)) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $Path = Split-Path -Parent $here
}
if (-not (Test-Path -LiteralPath $Path)) { throw "path not found: $Path" }
$root = (Resolve-Path -LiteralPath $Path).Path
$rootPrefix = $root.TrimEnd('\') + '\'

Write-Host "Java-Dev-Env-Script repo self-check"
Write-Host "host   : $($PSVersionTable.PSVersion) (CLR $([System.Environment]::Version))"
Write-Host "edition: $($PSVersionTable.PSEdition)"
Write-Host "root   : $root"

$utf8Strict = [Text.UTF8Encoding]::new($false, $true)
$rel = { param($f) $f.FullName.Substring($rootPrefix.Length) }

# Only check files that would actually be committed. Anything .gitignore'd
# (node_modules, cache, logs, .tmp*) is skipped - otherwise a local
# "npm install" would fail the BOM check on the .ps1 shims npm writes into
# node_modules\.bin.
$allFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force |
    Where-Object { $_.FullName -notmatch '\\\.git\\' })
$ignoredSet = @{}
if (Get-Command git -ErrorAction SilentlyContinue) {
    try {
        $relList = @($allFiles | ForEach-Object { & $rel $_ })
        if ($relList.Count -gt 0) {
            foreach ($line in @($relList | & git -C $root check-ignore --stdin 2>$null)) {
                $key = ([string]$line).Trim()
                if ($key) {
                    $ignoredSet[$key] = $true
                    $ignoredSet[$key.Replace('/', '\')] = $true
                }
            }
        }
    } catch {
        Write-Soft "git check-ignore failed: $($_.Exception.Message)"
    }
}
if ($ignoredSet.Count -gt 0) {
    $allFiles = @($allFiles | Where-Object { -not $ignoredSet.ContainsKey((& $rel $_)) })
} else {
    # no git available - fall back to excluding the usual output folders
    $allFiles = @($allFiles | Where-Object { $_.FullName -notmatch '\\(node_modules|cache|logs|\.tmp[^\\]*)\\' })
}
Write-Host "files  : $($allFiles.Count) (would be committed)"
if ($allFiles.Count -eq 0) {
    Write-Soft 'nothing to check - is every file in this tree gitignored?'
}

$ps1Files = @($allFiles | Where-Object { $_.Extension -eq '.ps1' })
$cmdFiles = @($allFiles | Where-Object { $_.Extension -in @('.cmd', '.bat') })
$jsonFiles = @($allFiles | Where-Object { $_.Extension -eq '.json' })
$textFiles = @($allFiles | Where-Object { $_.Extension -in @('.ps1', '.cmd', '.bat', '.json', '.md', '.yml', '.yaml', '.txt') -or $_.Name -in @('.gitignore', '.gitattributes') })

# ---------------------------------------------------------------- 1. .ps1 BOM
Write-Head "1. every .ps1 has a UTF-8 BOM ($($ps1Files.Count) files)"
foreach ($f in $ps1Files) {
    $name = & $rel $f
    $b = [IO.File]::ReadAllBytes($f.FullName)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
        Write-Ok $name
    } elseif ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) {
        Write-Bad "$name : UTF-16 BOM (must be UTF-8 with BOM)"
    } else {
        Write-Bad "$name : missing UTF-8 BOM - Windows PowerShell 5.1 will read it as GBK"
    }
}

# ------------------------------------------------------------- 2. .cmd no BOM
Write-Head "2. no .cmd/.bat has a BOM ($($cmdFiles.Count) files)"
foreach ($f in $cmdFiles) {
    $name = & $rel $f
    $b = [IO.File]::ReadAllBytes($f.FullName)
    if (($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) -or
        ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE)) {
        Write-Bad "$name : has a BOM - cmd.exe will choke on it"
    } else {
        Write-Ok $name
    }
}

# --------------------------------------------------------- 3. strict UTF-8 text
Write-Head "3. all text files are valid UTF-8 ($($textFiles.Count) files)"
foreach ($f in $textFiles) {
    $name = & $rel $f
    try {
        $null = $utf8Strict.GetString([IO.File]::ReadAllBytes($f.FullName))
    } catch {
        Write-Bad "$name : not valid UTF-8 (saved as GBK/ANSI?)"
    }
}
if ($script:ErrorCount -eq 0) { Write-Ok 'all text files decode as UTF-8' }

# ------------------------------------------------------------- 4. parse .ps1
Write-Head "4. every .ps1 parses under this host ($($ps1Files.Count) files)"
foreach ($f in $ps1Files) {
    $name = & $rel $f
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and @($parseErrors).Count -gt 0) {
        foreach ($e in @($parseErrors)) {
            Write-Bad ("{0}:{1}: {2}" -f $name, $e.Extent.StartLineNumber, $e.Message)
        }
    } else {
        Write-Ok $name
    }
}

# -------------------------------------------------------------- 5. JSON valid
Write-Head "5. every .json parses ($($jsonFiles.Count) files)"
foreach ($f in $jsonFiles) {
    $name = & $rel $f
    try {
        $text = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
        $null = $text | ConvertFrom-Json
        Write-Ok $name
    } catch {
        Write-Bad "$name : invalid JSON - $($_.Exception.Message)"
    }
}

# --------------------------------------------------- 6. personal data / tokens
Write-Head '6. no personal paths or credentials in tracked text files'
$patterns = @(
    @{ Name = 'hardcoded user profile path'; Pattern = 'C:\\Users\\[A-Za-z0-9._-]+\\' },
    @{ Name = 'GitHub token'; Pattern = 'gh[pousr]_[A-Za-z0-9]{20,}' },
    @{ Name = 'API key (sk-...)'; Pattern = 'sk-[A-Za-z0-9]{20,}' },
    @{ Name = 'private key block'; Pattern = 'BEGIN [A-Z ]*PRIVATE KEY' }
)
$hits = 0
foreach ($f in $textFiles) {
    $name = & $rel $f
    $text = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
    foreach ($p in $patterns) {
        if ($text -match $p.Pattern) { $hits++; Write-Soft "$name : possible $($p.Name)" }
    }
}
if ($hits -eq 0) { Write-Ok 'nothing suspicious found' }

# ------------------------------------------- 7. config\user.json stays ignored
Write-Head '7. local config is gitignored'
if (Get-Command git -ErrorAction SilentlyContinue) {
    $null = & git -C $root check-ignore -q 'config/user.json' 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Ok 'config/user.json is ignored (it may contain passwords and private paths)'
    } else {
        Write-Bad 'config/user.json is NOT ignored - local passwords/paths could be committed'
    }
} else {
    Write-Soft 'git not found, skipped'
}

# -------------------------------------------------------------------- summary
Write-Host ''
Write-Host ("checks finished: errors=$script:ErrorCount warnings=$script:WarnCount")
if ($script:ErrorCount -gt 0) {
    Write-Host 'RESULT: FAILED' -ForegroundColor Red
    exit 1
}
Write-Host 'RESULT: PASSED' -ForegroundColor Green
exit 0
