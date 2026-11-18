<#
  更新控制台：替换「Claude 保护」托盘程序、守护脚本与内置引擎文件，不重启 Clash、不改防火墙、不断网。
  · 覆盖前把当前已安装的版本存一份到 C:\ProgramData\ClaudeGuard\versions（保留最近 5 个），可在控制台「维护」里一键回退
  · 准备内置引擎：复制内核（来自本机 Clash Verge）、建目录、从 Clash Verge 复制一份白羊订阅；不会自动切换引擎
#>
param([switch]$NoPause)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$SuiteVersion = '10.8'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath)
    exit
}
$suite = $PSScriptRoot
$gr  = 'C:\ProgramData\ClaudeGuard'
$bin = Join-Path $gr 'bin'
if (-not (Test-Path -LiteralPath $bin)) { Write-Host '尚未安装，请先双击「1-安装或更新.bat」。' -ForegroundColor Red; Read-Host '按回车键关闭' | Out-Null; exit 1 }
Write-Host ("==== 更新 Claude 保护到 v{0}（不断网） ====" -f $SuiteVersion) -ForegroundColor Cyan
$utf8Bom = New-Object System.Text.UTF8Encoding($true)

$map = [ordered]@{
    'Config_Template\scripts\SecurityHub.ps1'          = 'SecurityHub.ps1'
    'Config_Template\scripts\ClaudeHub.vbs'            = 'ClaudeHub.vbs'
    'Config_Template\scripts\ClaudeGuard.ps1'          = 'ClaudeGuard.ps1'
    'Resume-恢复保护.ps1'                               = 'Resume.ps1'
    'Pause-关闭保护.ps1'                                = 'Pause.ps1'
    'Rescue-恢复网络.ps1'                               = 'Rescue.ps1'
    'Config_Template\scripts\BaiyangProfile.ps1'       = 'BaiyangProfile.ps1'
    'Config_Template\scripts\BuiltinCore.ps1'          = 'BuiltinCore.ps1'
    'Config_Template\scripts\NetMonitor.ps1'           = 'NetMonitor.ps1'
    'Config_Template\scripts\Refresh-Subscription.ps1' = 'Refresh-Subscription.ps1'
    'Config_Template\profiles\sRYohxTjB2to.js'         = 'strict-profile.js'
    'Switch-热切换.ps1'                                 = 'Switch.ps1'
    'Config_Template\scripts\cg-guard.exe'             = 'cg-guard.exe'      # 10.0 起：Rust 版守护
    'Config_Template\scripts\cg-hub.exe'               = 'cg-hub.exe'        # 10.1 起：新界面（Tauri）；10.2 起为主控制台
    'Config_Template\scripts\HubData.ps1'              = 'HubData.ps1'       # 10.2 起：新界面的数据助手（订阅 / 节点 / 进程）
}

# 文本文件按内容比较（忽略 BOM 差异）；程序文件按字节比较
function Test-SameFile([string]$a, [string]$b) {
    if ($a -like '*.exe') {
        $fa = Get-Item -LiteralPath $a; $fb = Get-Item -LiteralPath $b
        if ($fa.Length -ne $fb.Length) { return $false }
        return ((Get-FileHash -LiteralPath $a -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $b -Algorithm SHA256).Hash)
    }
    return ([IO.File]::ReadAllText($a, [Text.Encoding]::UTF8) -eq [IO.File]::ReadAllText($b, [Text.Encoding]::UTF8))
}

# ---------------------------------------------------------------- 1. 先保存当前已安装的版本（有改动才存）
function Get-InstalledVersion {
    try { $t = [IO.File]::ReadAllText((Join-Path $bin 'SecurityHub.ps1'), [Text.Encoding]::UTF8); if ($t -match "(?m)^\`$HubVersion\s*=\s*'([^']+)'") { return $Matches[1] } } catch {}
    return '?'
}
$diff = @()
foreach ($k in $map.Keys) {
    $src = Join-Path $suite $k; $dst = Join-Path $bin $map[$k]
    if (-not (Test-Path -LiteralPath $src)) { continue }
    if (-not (Test-Path -LiteralPath $dst)) { $diff += $map[$k]; continue }
    if (-not (Test-SameFile $src $dst)) { $diff += $map[$k] }
}
$verRoot = Join-Path $gr 'versions'
if ($diff.Count -gt 0) {
    $oldVer = Get-InstalledVersion
    $id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '_v' + $oldVer
    $snap = Join-Path $verRoot $id
    New-Item -ItemType Directory -Path $snap -Force | Out-Null
    Get-ChildItem -LiteralPath $bin -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $snap $_.Name) -Force }
    $meta = [ordered]@{ id = $id; version = $oldVer; ts = (Get-Date).ToString('o'); note = ('升级到 v{0} 前自动保存' -f $SuiteVersion); files = @(Get-ChildItem -LiteralPath $snap -File | ForEach-Object { $_.Name }) }
    [IO.File]::WriteAllText((Join-Path $snap 'version.json'), ($meta | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("  [OK] 已保存当前版本 v{0}（可在控制台「维护」里回退）" -f $oldVer) -ForegroundColor Green
    # 只保留最近 5 个
    $all = @(Get-ChildItem -LiteralPath $verRoot -Directory | Sort-Object Name -Descending)
    foreach ($o in ($all | Select-Object -Skip 5)) { Remove-Item -LiteralPath $o.FullName -Recurse -Force -ErrorAction SilentlyContinue }
} else { Write-Host '  程序文件与套件文件夹一致，无需保存旧版本' }

# ---------------------------------------------------------------- 2. 替换文件
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'SecurityHub\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
# 守护程序文件运行中无法替换：先停守护（防火墙“默认拒绝”保持不变，不会漏），换完文件再按原状态启动
$guardWasRunning = $false
try {
    $task = Get-ScheduledTask -TaskName 'ClaudeGuard' -ErrorAction Stop
    if ($task.State -eq 'Running') { $guardWasRunning = $true; Stop-ScheduledTask -TaskName 'ClaudeGuard' }
} catch {}
Get-Process -Name 'cg-guard', 'cg-hub' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
for ($i = 0; $i -lt 20 -and (Get-Process -Name 'cg-guard', 'cg-hub' -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }
Start-Sleep -Milliseconds 500
foreach ($k in $map.Keys) {
    $src = Join-Path $suite $k
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $bin $map[$k]) -Force; Write-Host ('  [OK] ' + $map[$k]) -ForegroundColor Green }
    else { Write-Host ('  [缺失] ' + $k) -ForegroundColor Red }
}
# PowerShell 5.1 需要 BOM 才能正确读取中文脚本
foreach ($f in @(Get-ChildItem -LiteralPath $bin -Filter '*.ps1' -File)) {
    $t = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8); [IO.File]::WriteAllText($f.FullName, $t, $utf8Bom)
}

# 回退脚本放在 bin 之外（回退时 bin 会被整体替换）
$rbDir = Join-Path $gr 'rollback'
New-Item -ItemType Directory -Path $rbDir -Force | Out-Null
$rbSrc = Join-Path $suite '回退-Claude保护版本.ps1'
if (Test-Path -LiteralPath $rbSrc) {
    $t = [IO.File]::ReadAllText($rbSrc, [Text.Encoding]::UTF8); [IO.File]::WriteAllText((Join-Path $rbDir 'Rollback.ps1'), $t, $utf8Bom)
    Write-Host '  [OK] 版本回退工具' -ForegroundColor Green
}

# ---------------------------------------------------------------- 3. 准备内置引擎（不切换、不启动）
try {
    . (Join-Path $bin 'BaiyangProfile.ps1'); . (Join-Path $bin 'BuiltinCore.ps1')
    Initialize-BCDirs
    Write-Host ('  [OK] ' + (Install-BCCoreExe)) -ForegroundColor Green
    if (Initialize-BCSub) { Write-Host '  [OK] 内置引擎订阅已就绪' -ForegroundColor Green } else { Write-Host '  [注意] 没有从 Clash Verge 找到白羊订阅，开启内置引擎前请先导入一次' -ForegroundColor Yellow }
    $S = Get-BCSettings; if (-not $S.secret) { Save-BCSettings $S }
    Write-Host ('  当前引擎：' + $(if ($S.engine -eq 'builtin') { '内置引擎' } else { 'Clash Verge（在控制台概览的「运行模式」里可直接热切换到内置引擎）' }))
} catch { Write-Host ('  [注意] 准备内置引擎失败：' + $_.Exception.Message) -ForegroundColor Yellow }

# ---------------------------------------------------------------- 4. 计划任务指向新守护程序，原来在运行就重新启动
# 停止期间防火墙“默认拒绝”保持不变，不会漏；守护热启动：本地体检通过就沿用放行状态，Claude 不中断
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'ClaudeGuard.ps1') -Mode RegisterTask -Quiet
    $which = $(if (Test-Path -LiteralPath (Join-Path $bin 'cg-guard.exe')) { 'Rust 版 cg-guard.exe' } else { 'ClaudeGuard.ps1' })
    if ($guardWasRunning) {
        Start-ScheduledTask -TaskName 'ClaudeGuard'
        Write-Host ("  [OK] 守护已切换到 {0} 并重新启动（热启动，不中断 Claude）" -f $which) -ForegroundColor Green
    } else {
        Write-Host ("  [OK] 守护程序已更新为 {0}（保护当前关闭，开启时生效）" -f $which) -ForegroundColor Green
    }
} catch { Write-Host ('  [注意] 更新守护计划任务失败：' + $_.Exception.Message) -ForegroundColor Yellow; if ($guardWasRunning) { try { Start-ScheduledTask -TaskName 'ClaudeGuard' } catch {} } }

# ---------------------------------------------------------------- 5. 快捷方式
$wsh = New-Object -ComObject WScript.Shell
$desk = [Environment]::GetFolderPath('Desktop')
$s1 = $wsh.CreateShortcut((Join-Path $desk 'Claude保护.lnk'))
$s1.TargetPath = Join-Path $env:windir 'System32\wscript.exe'
$s1.Arguments = ('"{0}"' -f (Join-Path $bin 'ClaudeHub.vbs'))
$hubExe = Join-Path $bin 'cg-hub.exe'
$hubIcon = $(if (Test-Path -LiteralPath $hubExe) { "$hubExe,0" } else { "$env:windir\System32\imageres.dll,102" })
$s1.IconLocation = $hubIcon
$s1.Description = 'Claude 保护：开启=放心使用 Claude；关闭=正常上网'
$s1.Save()
Write-Host '  [OK] 桌面「Claude保护」' -ForegroundColor Green

# 记录套件文件夹位置与版本：控制台据此检测新版本、执行更新/完整修复
[IO.File]::WriteAllText((Join-Path $gr 'suite.json'), ([ordered]@{ path = $suite; version = $SuiteVersion; updated = (Get-Date).ToString('o') } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))

foreach ($n in @('Claude保护-更新.lnk', 'Claude保护-一键升级.lnk', '应急恢复网络.lnk')) {
    $p = Join-Path $desk $n
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; Write-Host "  [OK] 已移除桌面「$($n -replace '\.lnk$','')」（已合并进控制台）" -ForegroundColor Green }
}
# 保底：开始菜单「Claude保护」文件夹（控制台本身打不开时用）
$sm = Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude保护'
New-Item -ItemType Directory -Path $sm -Force | Out-Null
$s3 = $wsh.CreateShortcut((Join-Path $sm '应急恢复网络.lnk'))
$s3.TargetPath = 'powershell.exe'
$s3.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $bin 'Rescue.ps1'))
$s3.IconLocation = "$env:windir\System32\imageres.dll,100"
$s3.Description = '应急：立即恢复默认网络（控制台打不开时使用）'
$s3.Save()
$s4 = $wsh.CreateShortcut((Join-Path $sm 'Claude保护.lnk'))
$s4.TargetPath = Join-Path $env:windir 'System32\wscript.exe'
$s4.Arguments = ('"{0}"' -f (Join-Path $bin 'ClaudeHub.vbs'))
$s4.IconLocation = $hubIcon
$s4.Save()
# 10.2 起「Claude保护」就是新界面，单独的「新界面」入口不再需要；旧控制台保留一个备用入口
Remove-Item -LiteralPath (Join-Path $sm 'Claude保护 新界面.lnk') -Force -ErrorAction SilentlyContinue
$s6 = $wsh.CreateShortcut((Join-Path $sm '旧控制台（备用）.lnk'))
$s6.TargetPath = Join-Path $env:windir 'System32\wscript.exe'
$s6.Arguments = ('"{0}" -Legacy' -f (Join-Path $bin 'ClaudeHub.vbs'))
$s6.IconLocation = "$env:windir\System32\imageres.dll,102"
$s6.Description = '旧版 PowerShell 控制台（新界面有问题时使用）'
$s6.Save()
if (Test-Path -LiteralPath (Join-Path $rbDir 'Rollback.ps1')) {
    $s5 = $wsh.CreateShortcut((Join-Path $sm '回退到旧版本.lnk'))
    $s5.TargetPath = 'powershell.exe'
    $s5.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $rbDir 'Rollback.ps1'))
    $s5.IconLocation = "$env:windir\System32\imageres.dll,229"
    $s5.Description = '把 Claude 保护回退到之前保存的版本（控制台打不开时使用）'
    $s5.Save()
}
Write-Host '  [OK] 开始菜单「Claude保护」：控制台 + 应急恢复网络 + 回退到旧版本 + 旧控制台（备用）' -ForegroundColor Green

# 以普通用户身份启动（经 explorer 降权）
Start-Process explorer.exe -ArgumentList ('"{0}"' -f (Join-Path $bin 'ClaudeHub.vbs'))
Write-Host ''
Write-Host ("完成：已更新到 v{0}，新控制台已启动。" -f $SuiteVersion) -ForegroundColor Green
Write-Host '保护开着时可在控制台「运行模式」里直接热切换（内置引擎 / Clash Verge）；有问题可在「维护」里回退。' -ForegroundColor Green
if (-not $NoPause) { Start-Sleep -Seconds 3 }
