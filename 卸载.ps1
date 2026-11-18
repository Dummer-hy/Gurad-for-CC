<#
  卸载「Claude 保护」
  先关闭保护、把网络恢复成默认（防火墙、IPv6、hosts、系统代理、Clash Verge 配置），
  再删除计划任务、快捷方式和 C:\ProgramData\ClaudeGuard。Clash Verge 本身不会被卸载。
#>
param([switch]$Yes)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $a = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    if ($Yes) { $a += ' -Yes' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $a
    exit
}
$gr = 'C:\ProgramData\ClaudeGuard'
$bin = Join-Path $gr 'bin'
Write-Host '==== 卸载 Claude 保护 ====' -ForegroundColor Yellow
Write-Host '会先恢复正常上网，再删除程序、计划任务和快捷方式。Clash Verge 本身不受影响。'
if (-not $Yes) {
    $r = Read-Host '确认卸载请输入 Y 后回车'
    if ($r -notmatch '^[Yy]') { Write-Host '已取消。'; Start-Sleep -Seconds 2; exit }
}

# ---------------------------------------------------------------- 1. 关闭保护、恢复网络
$cg = Join-Path $bin 'cg-guard.exe'
$off = $false
if (Test-Path -LiteralPath $cg) {
    Write-Host '正在关闭保护…'
    & $cg off --config Strict | Out-Host
    $off = ($LASTEXITCODE -eq 0)
}
$guardPs = Join-Path $bin 'ClaudeGuard.ps1'
if (Test-Path -LiteralPath $guardPs) {
    # 应急恢复（防火墙默认动作、ClaudeGuard 规则、IPv6、hosts）+ 删除守护计划任务
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $guardPs -Mode Uninstall | Out-Host
} elseif (-not $off) {
    foreach ($p in 'Domain', 'Private', 'Public') { try { Set-NetFirewallProfile -Profile $p -DefaultOutboundAction NotConfigured -ErrorAction Stop } catch {} }
    Get-NetFirewallRule -Group 'ClaudeGuard' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
}
foreach ($t in 'ClaudeGuard', 'ClaudeGuardCore') { schtasks.exe /Delete /TN $t /F 2>&1 | Out-Null }
Write-Host '  [OK] 已关闭保护并删除计划任务' -ForegroundColor Green

# ---------------------------------------------------------------- 2. 结束程序
Get-Process -Name 'cg-hub', 'cg-guard', 'cg-mihomo' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'SecurityHub\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1

# ---------------------------------------------------------------- 3. 系统代理、Clash Verge 服务
try {
    $ik = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $pp = Get-ItemProperty -LiteralPath $ik -ErrorAction Stop
    if ([int]$pp.ProxyEnable -eq 1 -and [string]$pp.ProxyServer -match '^(http=)?127\.0\.0\.1:17897$') { Set-ItemProperty -LiteralPath $ik -Name ProxyEnable -Value 0 -Type DWord; Write-Host '  [OK] 已关闭指向内置引擎的系统代理' -ForegroundColor Green }
} catch {}
# 切换引擎时可能暂停过 Clash Verge 的后台服务：恢复它
$q = (sc.exe query clash_verge_service 2>$null | Out-String)
if ($q -match 'STATE\s*:\s*1\b') { sc.exe start clash_verge_service 2>&1 | Out-Null; Write-Host '  [OK] 已恢复 Clash Verge 后台服务' -ForegroundColor Green }
Clear-DnsClientCache -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- 4. 快捷方式与文件
$desk = [Environment]::GetFolderPath('Desktop')
foreach ($f in @((Join-Path $desk 'Claude保护.lnk'), (Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude保护.lnk'))) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude保护') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'ClaudeGuardHub') -Recurse -Force -ErrorAction SilentlyContinue
& icacls.exe $gr /reset /T /C /Q 2>&1 | Out-Null
Remove-Item -LiteralPath $gr -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $gr) { Write-Host "  [注意] 有文件正被占用，没删干净：$gr（重启电脑后可手动删除）" -ForegroundColor Yellow }
else { Write-Host '  [OK] 已删除 C:\ProgramData\ClaudeGuard' -ForegroundColor Green }

Write-Host ''
Write-Host '卸载完成：现在是正常上网。本文件夹可以直接删除。' -ForegroundColor Green
Read-Host '按回车键关闭' | Out-Null
