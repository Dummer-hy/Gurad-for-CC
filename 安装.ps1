<#
  安装或更新「Claude 保护」
  · 第一次运行：把程序装到 C:\ProgramData\ClaudeGuard，建桌面快捷方式并打开控制台。
    只安装程序：不会开启保护、不改防火墙、不动 Clash Verge，装完仍是正常上网。
  · 已经装过：等同于「更新控制台」，替换为本文件夹里的版本（不断网）。
  不需要事先安装 Clash Verge：没有它时自动使用自带的内置引擎（mihomo 内核随包附带）。
#>
param([switch]$NoPause)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath)
    exit
}
function Done([int]$code) { if (-not $NoPause) { Write-Host ''; Read-Host '按回车键关闭' | Out-Null }; exit $code }

$suite = $PSScriptRoot
$gr = 'C:\ProgramData\ClaudeGuard'
$bin = Join-Path $gr 'bin'
$updater = Join-Path $suite '更新控制台.ps1'
if (-not (Test-Path -LiteralPath $updater)) { Write-Host '文件夹不完整：缺少「更新控制台.ps1」，请重新解压。' -ForegroundColor Red; Done 1 }

# ---------------------------------------------------------------- 已安装：直接更新
if (Test-Path -LiteralPath (Join-Path $bin 'cg-guard.exe')) {
    Write-Host '检测到已经安装过 Claude 保护，执行更新…' -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updater -NoPause
    Done $LASTEXITCODE
}

Write-Host '==== 安装 Claude 保护 ====' -ForegroundColor Cyan
Write-Host '只安装程序：不会开启保护、不改防火墙，装完仍是正常上网。'
Write-Host ''

# ---------------------------------------------------------------- 1. 目录与权限
foreach ($d in @($gr, $bin, (Join-Path $gr 'state'), (Join-Path $gr 'logs'), (Join-Path $gr 'commands'), (Join-Path $gr 'core'))) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}
# 程序目录只允许管理员 / SYSTEM 改；控制台以普通用户身份给守护发指令（commands 目录可写）
& icacls.exe $gr /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' 2>&1 | Out-Null
& icacls.exe (Join-Path $gr 'commands') /grant '*S-1-5-32-545:(OI)(CI)M' 2>&1 | Out-Null
Write-Host '  [OK] 程序目录 C:\ProgramData\ClaudeGuard' -ForegroundColor Green

# ---------------------------------------------------------------- 2. 找本机的 Clash Verge（可选）
$vergeDir = $null
$cands = @()
$p = Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
if ($p) { $cands += (Split-Path -Parent $p.Path) }
$cands += @("$env:ProgramFiles\Clash Verge", "${env:ProgramFiles(x86)}\Clash Verge", "$env:LOCALAPPDATA\Programs\Clash Verge", "$env:LOCALAPPDATA\Clash Verge")
foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    try { Get-ItemProperty $k -ErrorAction Stop | Where-Object { $_.DisplayName -like 'Clash Verge*' -and $_.InstallLocation } | ForEach-Object { $cands += $_.InstallLocation.Trim('"') } } catch {}
}
foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath (Join-Path $c 'clash-verge.exe'))) { $vergeDir = $c; break } }
if ($vergeDir) { Write-Host "  [OK] 找到 Clash Verge：$vergeDir" -ForegroundColor Green }
else { Write-Host '  没有找到 Clash Verge：将使用自带的内置引擎（不影响使用）' }

# ---------------------------------------------------------------- 3. 守护配置（按本机用户路径生成）
$cfgFile = Join-Path $gr 'guard.config.json'
if (-not (Test-Path -LiteralPath $cfgFile)) {
    $globs = @(
        (Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe'),
        (Join-Path $env:LOCALAPPDATA 'AnthropicClaude\app-*\claude.exe'),
        (Join-Path $env:APPDATA 'Claude\claude-code\*\*\claude.exe'),
        (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Antigravity*\Antigravity*.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Claude*\*.exe')
    )
    $cfg = [ordered]@{
        coreRoots          = @($(if ($vergeDir) { $vergeDir }))
        runtimeYaml        = (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml')
        claudeProgramGlobs = $globs
        denyCorePathLike   = @()
        probeProxy         = ''
        extraAllowPrograms = @()
        probeIntervalSec   = 300
        probeRetrySec      = 60
        probeTimeoutSec    = 15
        hardRecoverTicks   = 3
        recoverThreshold   = 2
        expectedCountry    = 'KR'
        allowedAsns        = @()
        strictAsn          = $false
        tunAlias           = 'Mihomo'
        tunLocalCidr       = '198.18.0.0/24'
    }
    [IO.File]::WriteAllText($cfgFile, ($cfg | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host '  [OK] 守护配置（期望出口国家会在选好节点、开启保护时自动设置）' -ForegroundColor Green
}

# ---------------------------------------------------------------- 4. 自带的内置内核
$coreSrc = Join-Path $suite 'Config_Template\core\cg-mihomo.exe'
$coreDst = Join-Path $gr 'core\cg-mihomo.exe'
if ((Test-Path -LiteralPath $coreSrc) -and -not (Test-Path -LiteralPath $coreDst)) {
    Copy-Item -LiteralPath $coreSrc -Destination $coreDst -Force
    Write-Host '  [OK] 内置引擎内核（mihomo）' -ForegroundColor Green
}

# ---------------------------------------------------------------- 5. 复制程序、快捷方式、启动控制台（与「更新控制台」同一套流程）
Write-Host ''
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updater -NoPause
$code = $LASTEXITCODE
# 全新安装时「更新控制台」会给空的旧版本存一份快照，删掉（不能回退到它）
Get-ChildItem -LiteralPath (Join-Path $gr 'versions') -Directory -ErrorAction SilentlyContinue |
    Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Filter '*.exe' -File -ErrorAction SilentlyContinue) } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
if (-not (Test-Path -LiteralPath (Join-Path $bin 'cg-guard.exe'))) { Write-Host '安装没有完成（见上方提示）。' -ForegroundColor Red; Done 1 }

# ---------------------------------------------------------------- 6. 选默认引擎
$hasSub = $false
try {
    . (Join-Path $bin 'BaiyangProfile.ps1'); . (Join-Path $bin 'BuiltinCore.ps1')
    try { $hasSub = [bool](Initialize-BCSub) } catch { $hasSub = $false }
    $S = Get-BCSettings
    if (-not $vergeDir -or -not $hasSub) {
        $S.engine = 'builtin'; $S.netMode = 'tun'
        if (-not $hasSub) { $S.subSource = 'local' }
    }
    Save-BCSettings $S
} catch { Write-Host ('  [注意] 设置默认引擎失败：' + $_.Exception.Message) -ForegroundColor Yellow }

Write-Host ''
Write-Host '==== 安装完成 ====' -ForegroundColor Green
Write-Host '桌面已有「Claude保护」，控制台已打开。现在仍是正常上网，保护还没开启。'
Write-Host ''
if ($hasSub) {
    Write-Host '检测到 Clash Verge 里的白羊订阅：在控制台「节点与引擎」选好节点，回到「概览」点「开启保护」即可。'
} else {
    Write-Host '下一步（没有白羊订阅时）：' -ForegroundColor Cyan
    Write-Host '  1. 控制台 →「节点与引擎」→「导入本地配置」，选你自己的 Clash / mihomo 配置文件（只会用其中的节点）；'
    Write-Host '  2. 在节点列表里选一个要锁定的节点；'
    Write-Host '  3. 回到「概览」点「开启保护」。'
}
Write-Host '出问题时：双击本文件夹的「2-应急恢复网络.bat」，或开始菜单 → Claude保护 → 应急恢复网络。'
Done $code
