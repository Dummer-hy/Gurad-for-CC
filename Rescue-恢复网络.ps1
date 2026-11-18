<#
  应急恢复网络：撤销防火墙默认拒绝 / 全部 ClaudeGuard 规则 / hosts 黑洞 / IPv6 解绑，并停用看门狗。
  不依赖网络、不依赖 Clash，随时可用。恢复后网络会回落为直连。
#>
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath)
    exit
}

Write-Host '==== 应急恢复网络 ====' -ForegroundColor Yellow
$guard = 'C:\ProgramData\ClaudeGuard\bin\ClaudeGuard.ps1'
if (-not (Test-Path -LiteralPath $guard)) { $guard = Join-Path $PSScriptRoot 'Config_Template\scripts\ClaudeGuard.ps1' }

if (Test-Path -LiteralPath $guard) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $guard -Mode Rescue
} else {
    Write-Host '未找到 ClaudeGuard.ps1，使用内置兜底步骤…' -ForegroundColor Yellow
    Set-NetFirewallProfile -Profile Domain,Private,Public -DefaultOutboundAction NotConfigured
    Get-NetFirewallRule -Group ClaudeGuard -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Stop-ScheduledTask -TaskName ClaudeGuard -ErrorAction SilentlyContinue
    Disable-ScheduledTask -TaskName ClaudeGuard -ErrorAction SilentlyContinue | Out-Null
    Stop-ScheduledTask -TaskName ClaudeGuardCore -ErrorAction SilentlyContinue
    Disable-ScheduledTask -TaskName ClaudeGuardCore -ErrorAction SilentlyContinue | Out-Null
    Get-Process -Name 'cg-mihomo', 'cg-guard' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue | Where-Object { -not $_.Enabled -and $_.Name -ne 'Mihomo' } | ForEach-Object { Enable-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6 }
    $h = Join-Path $env:windir 'System32\drivers\etc\hosts'
    $lines = Get-Content -LiteralPath $h; $out = @(); $skip = $false
    foreach ($l in $lines) { if ($l -like '# >>> ClaudeGuard BEGIN*') { $skip = $true; continue }; if ($l -like '# <<< ClaudeGuard END*') { $skip = $false; continue }; if (-not $skip) { $out += $l } }
    [IO.File]::WriteAllLines($h, $out, (New-Object Text.UTF8Encoding($false)))
    Clear-DnsClientCache
}
# 内置引擎「系统代理」模式：系统代理指向已停止的内置内核端口时关掉它，否则浏览器会打不开网页
try {
    $ik = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $pp = Get-ItemProperty -LiteralPath $ik -ErrorAction Stop
    if ([int]$pp.ProxyEnable -eq 1 -and [string]$pp.ProxyServer -match '^(http=)?127\.0\.0\.1:17897$') { Set-ItemProperty -LiteralPath $ik -Name ProxyEnable -Value 0 -Type DWord; Write-Host '已关闭指向内置内核的系统代理' }
} catch {}
Unregister-ScheduledTask -TaskName 'ClaudeGuard-Rollback' -Confirm:$false -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '网络已恢复为默认状态（可直连）。看门狗已停用。' -ForegroundColor Green
Write-Host '重新启用保护：打开桌面「Claude保护」，点「开启保护」。' -ForegroundColor Green
Read-Host '按回车键关闭' | Out-Null
