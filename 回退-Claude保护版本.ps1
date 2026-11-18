<#
  回退 Claude保护 到之前保存的版本（每次「更新到最新版」前自动保存，见 C:\ProgramData\ClaudeGuard\versions）
  安装位置：C:\ProgramData\ClaudeGuard\rollback\Rollback.ps1（不在 bin 里，bin 坏了也能用）
  流程：关闭保护（恢复普通网络）→ 把当前版本也存一份（可再回来）→ 用所选版本替换程序文件 → 重启控制台
  目标版本没有内置引擎时，自动改回 Clash Verge 引擎。回退后需要重新「开启保护」。
  -Id <版本目录名>：直接回退到该版本（控制台调用）；不带参数：列出版本让你选
#>
param([string]$Id = '', [switch]$NoPause)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $a = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    if ($Id) { $a += ' -Id ' + $Id }
    if ($NoPause) { $a += ' -NoPause' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $a
    exit
}
$gr = 'C:\ProgramData\ClaudeGuard'
$bin = Join-Path $gr 'bin'
$verRoot = Join-Path $gr 'versions'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-Result([bool]$ok, [string]$msg) {
    try {
        $f = Join-Path $gr 'state\toggle-result.json'
        $o = [ordered]@{ action = 'rollback'; ok = $ok; message = $msg; ts = (Get-Date).ToString('o') }
        [IO.File]::WriteAllText($f, ($o | ConvertTo-Json), $utf8)
    } catch {}
}
function Finish([int]$code, [string]$msg) {
    Write-Result ($code -eq 0) $msg
    Write-Host ''; Write-Host $msg -ForegroundColor $(if ($code -eq 0) { 'Green' } else { 'Red' })
    if (-not $NoPause) { Read-Host '按回车键关闭' | Out-Null }
    exit $code
}
function Get-Versions {
    if (-not (Test-Path -LiteralPath $verRoot)) { return @() }
    @(Get-ChildItem -LiteralPath $verRoot -Directory | Sort-Object Name -Descending | ForEach-Object {
        $m = $null; try { $m = Get-Content -LiteralPath (Join-Path $_.FullName 'version.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
        [pscustomobject]@{ id = $_.Name; path = $_.FullName; version = $(if ($m) { [string]$m.version } else { '?' }); ts = $(if ($m) { [string]$m.ts } else { '' }); note = $(if ($m) { [string]$m.note } else { '' }) }
    })
}
function Get-InstalledVersion {
    try { $t = [IO.File]::ReadAllText((Join-Path $bin 'SecurityHub.ps1'), [Text.Encoding]::UTF8); if ($t -match "(?m)^\`$HubVersion\s*=\s*'([^']+)'") { return $Matches[1] } } catch {}
    return '?'
}

Write-Host '==== 回退 Claude 保护版本 ====' -ForegroundColor Yellow
$list = @(Get-Versions)
if ($list.Count -eq 0) { Finish 1 '没有保存过的旧版本（每次「更新到最新版」时才会自动保存）。' }
$target = $null
if ($Id) { $target = @($list | Where-Object { $_.id -eq $Id })[0] }
else {
    Write-Host ("当前版本：v{0}" -f (Get-InstalledVersion))
    for ($i = 0; $i -lt $list.Count; $i++) {
        $t = ''; try { $t = ([datetime]$list[$i].ts).ToString('yyyy-MM-dd HH:mm') } catch {}
        Write-Host ("  [{0}] v{1}　保存于 {2}　{3}" -f ($i + 1), $list[$i].version, $t, $list[$i].note)
    }
    $n = Read-Host '输入要回退到的编号（直接回车取消）'
    if (-not $n) { exit 0 }
    $k = 0; if ([int]::TryParse($n, [ref]$k) -and $k -ge 1 -and $k -le $list.Count) { $target = $list[$k - 1] }
}
if (-not $target) { Finish 1 '没有找到要回退的版本。' }
if (-not (Test-Path -LiteralPath (Join-Path $target.path 'ClaudeGuard.ps1'))) { Finish 1 ('版本 {0} 文件不完整，无法回退。' -f $target.id) }
Write-Host ("回退到：v{0}（{1}）" -f $target.version, $target.id) -ForegroundColor Cyan

# 1. 关闭保护，恢复普通网络（用当前版本的关闭脚本；失败则用守护的应急恢复；再不行用内置兜底）
Write-Host '[1/4] 关闭保护…'
$pause = Join-Path $bin 'Pause.ps1'
if (Test-Path -LiteralPath $pause) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pause -NoPause -ConfigMode Strict | Out-Host }
$locked = $false; try { $locked = (@(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { $_.DefaultOutboundAction -eq 'Block' }).Count -gt 0) } catch {}
if ($locked) {
    Write-Host '      关闭脚本没有完全恢复，执行兜底恢复…' -ForegroundColor Yellow
    Set-NetFirewallProfile -Profile Domain,Private,Public -DefaultOutboundAction NotConfigured
    Get-NetFirewallRule -Group ClaudeGuard -ErrorAction SilentlyContinue | Remove-NetFirewallRule
}
foreach ($t in @('ClaudeGuard', 'ClaudeGuardCore')) {
    Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
    Disable-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue | Out-Null
}
Get-Process -Name 'cg-mihomo', 'cg-guard', 'cg-hub' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# 2. 当前版本也存一份（回退后还能再回来）
Write-Host '[2/4] 保存当前版本…'
$cur = Get-InstalledVersion
$curId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '_v' + $cur
$curDir = Join-Path $verRoot $curId
New-Item -ItemType Directory -Path $curDir -Force | Out-Null
Get-ChildItem -LiteralPath $bin -File -ErrorAction SilentlyContinue | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $curDir $_.Name) -Force }
$meta = [ordered]@{ id = $curId; version = $cur; ts = (Get-Date).ToString('o'); note = ('回退到 v{0} 前自动保存' -f $target.version) }
[IO.File]::WriteAllText((Join-Path $curDir 'version.json'), ($meta | ConvertTo-Json), $utf8)

# 3. 替换程序文件
Write-Host '[3/4] 替换程序文件…'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'SecurityHub\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 600
Get-ChildItem -LiteralPath $bin -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $target.path -File | Where-Object { $_.Name -ne 'version.json' } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $bin $_.Name) -Force }

# 4. 目标版本没有内置引擎：引擎改回 Clash Verge（守护配置里的内核路径/网卡名一并改回）
Write-Host '[4/4] 检查引擎设置…'
$hasBuiltin = Test-Path -LiteralPath (Join-Path $bin 'BuiltinCore.ps1')
$engFile = Join-Path $gr 'engine.json'
$eng = $null; try { $eng = Get-Content -LiteralPath $engFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
if (-not $hasBuiltin -and $eng -and $eng.engine -eq 'builtin') {
    $eng.engine = 'verge'
    [IO.File]::WriteAllText($engFile, ($eng | ConvertTo-Json), $utf8)
    $cf = Join-Path $gr 'guard.config.json'
    try {
        $c = Get-Content -LiteralPath $cf -Raw -Encoding UTF8 | ConvertFrom-Json
        $vr = @($c.vergeCoreRoots | Where-Object { $_ }); if ($vr.Count -eq 0) { $vr = @('D:\Program Files\uu\Clash Verge') }
        $c.coreRoots = $vr
        $c.coreNames = @('verge-mihomo.exe', 'verge-mihomo-alpha.exe')
        if ($c.vergeRuntimeYaml) { $c.runtimeYaml = [string]$c.vergeRuntimeYaml }
        $c.tunAlias = 'Mihomo'; $c.tunLocalCidr = '198.18.0.0/24'; $c.probeProxy = ''
        foreach ($k in @('engine', 'netMode', 'coreDiscovery')) { if ($c.PSObject.Properties.Name -contains $k) { $c.PSObject.Properties.Remove($k) } }
        [IO.File]::WriteAllText($cf, ($c | ConvertTo-Json -Depth 6), $utf8)
        Write-Host '      目标版本没有内置引擎，已改回 Clash Verge 引擎' -ForegroundColor Yellow
    } catch { Write-Host ('      改回 Clash Verge 引擎失败：' + $_.Exception.Message) -ForegroundColor Red }
}

Start-Process explorer.exe -ArgumentList ('"{0}"' -f (Join-Path $bin 'ClaudeHub.vbs'))
Finish 0 ("已回退到 v{0}。保护目前是关闭状态，需要时在控制台点「开启保护」。（回退前的 v{1} 也已保存，可以再回来）" -f $target.version, $cur)
