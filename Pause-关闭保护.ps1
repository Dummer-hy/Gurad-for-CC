<#
  关闭保护：撤销防火墙默认拒绝 / hosts 黑洞 / IPv6 封锁与解绑，停用看门狗，并退出 Clash Verge。
  -ConfigMode Strict（默认）：同时把 Clash 配置还原成「白羊原始配置」（开启保护前保存的快照 / 全部节点 + 官方规则）
  之后就是普通直连上网；需要白羊加速时直接打开白羊加速即可。
#>
param([switch]$NoPause, [ValidateSet('Strict', 'Keep')][string]$ConfigMode = 'Strict')
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $a = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigMode {1}' -f $PSCommandPath, $ConfigMode
    if ($NoPause) { $a += ' -NoPause' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $a
    exit
}
function Write-ToggleResult([string]$action, [bool]$ok, [string]$msg) {
    # 供「Claude 保护」托盘程序读取结果（本脚本在后台隐藏运行，用户看不到控制台输出）
    try {
        $f = 'C:\ProgramData\ClaudeGuard\state\toggle-result.json'
        New-Item -ItemType Directory -Path (Split-Path $f) -Force | Out-Null
        $o = [ordered]@{ action = $action; ok = $ok; message = $msg; ts = (Get-Date).ToString('o') }
        [IO.File]::WriteAllText($f, ($o | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}
# 10.6 起：整个关闭流程由 cg-guard.exe 完成，下面的 PowerShell 流程只在没有新版 cg-guard、
# 或它自身意外出错（返回 70）时使用。cg-guard 改用本脚本时会设置 CG_NO_NATIVE，避免来回调用。
$cgExe = 'C:\ProgramData\ClaudeGuard\bin\cg-guard.exe'
if (-not $env:CG_NO_NATIVE -and (Test-Path -LiteralPath $cgExe)) {
    $cgv = ''; try { $cgv = (& $cgExe version 2>$null | Out-String) } catch {}
    if ($cgv -match 'cg-guard (\d+)\.(\d+)' -and (([int]$Matches[1] -gt 7) -or ([int]$Matches[1] -eq 7 -and [int]$Matches[2] -ge 4))) {
        & $cgExe off --config $ConfigMode | Out-Host
        $cgCode = $LASTEXITCODE
        if ($cgCode -ne 70) { if (-not $NoPause) { Read-Host '按回车键关闭' | Out-Null }; exit $cgCode }
        Write-Host 'cg-guard 意外出错，改用 PowerShell 流程' -ForegroundColor Yellow
    }
}
Write-Host '==== 关闭保护 · 恢复正常上网 ====' -ForegroundColor Yellow
$guard = 'C:\ProgramData\ClaudeGuard\bin\ClaudeGuard.ps1'
if (-not (Test-Path -LiteralPath $guard)) { $guard = Join-Path $PSScriptRoot 'Config_Template\scripts\ClaudeGuard.ps1' }
function Invoke-GuardOp([string]$Mode) {
    # 7.2 起：开启 / 关闭保护的系统改动（防火墙规则、默认拒绝、IPv6、守护任务）由 cg-guard.exe 原生完成，
    # 它自己出错时会改用 ClaudeGuard.ps1 的同名模式。cg-guard 不存在、版本太旧或异常退出时，这里直接用旧脚本。
    $exe = Join-Path (Split-Path -Parent $guard) 'cg-guard.exe'
    $useExe = $false
    if (Test-Path -LiteralPath $exe) {
        try {
            $v = (& $exe version 2>$null | Out-String)
            if ($v -match 'cg-guard (\d+)\.(\d+)') { $useExe = ([int]$Matches[1] -gt 7) -or ([int]$Matches[1] -eq 7 -and [int]$Matches[2] -ge 2) }
        } catch {}
    }
    if ($useExe) {
        & $exe $Mode.ToLower() | Out-Host
        $code = $LASTEXITCODE
        if ($code -eq 0) { return 0 }
        # 开启：前置检查 / 出口验证没通过（已自动回滚），旧脚本也会一样失败，不再重复
        if ($Mode -eq 'Resume' -and $code -eq 1) { return 1 }
        Write-Host ("cg-guard {0} 没有完成（返回 {1}），改用旧脚本" -f $Mode.ToLower(), $code) -ForegroundColor Yellow
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $guard -Mode $Mode | Out-Host
    return $LASTEXITCODE
}
if (Test-Path -LiteralPath $guard) { [void](Invoke-GuardOp 'Rescue') }
else { Write-Host '未找到 ClaudeGuard.ps1，请改用 Rescue-恢复网络.bat。' -ForegroundColor Red }

# 当前引擎：内置引擎时守护的应急恢复已经停掉了自带内核，不去动电脑上的 Clash Verge
$engine = 'verge'
try { $e = Get-Content -LiteralPath 'C:\ProgramData\ClaudeGuard\engine.json' -Raw -Encoding UTF8 | ConvertFrom-Json; if ($e.engine) { $engine = [string]$e.engine } } catch {}
Get-Process -Name 'cg-mihomo' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
if ($engine -ne 'builtin') {
    Write-Host '正在退出 Clash Verge…'
    Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Get-Process -Name 'verge-mihomo', 'verge-mihomo-alpha' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
} else { Write-Host '内置内核已停止。' }
# 修复脚本若临时改过网卡 DNS，这里还原成原来的（DHCP 自动获取或原静态地址）
$origFile = 'C:\ProgramData\ClaudeGuard\state\net-original.json'
if (Test-Path -LiteralPath $origFile) {
    try {
        $o = Get-Content -LiteralPath $origFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $static = @(([string]$o.staticDns) -split '[,\s]+' | Where-Object { $_ })
        if ($static.Count -gt 0) { Set-DnsClientServerAddress -InterfaceAlias $o.alias -ServerAddresses $static -ErrorAction Stop }
        else { Set-DnsClientServerAddress -InterfaceAlias $o.alias -ResetServerAddresses -ErrorAction Stop }
        Remove-Item -LiteralPath $origFile -Force -ErrorAction SilentlyContinue
        Write-Host ("已还原网卡 {0} 的原始 DNS 设置" -f $o.alias)
    } catch { Write-Host ("还原 DNS 失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow }
}
Clear-DnsClientCache
# 内置引擎「系统代理」模式：系统代理指向已停止的内置内核端口时关掉它，否则浏览器会打不开网页
try {
    $ik = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $pp = Get-ItemProperty -LiteralPath $ik -ErrorAction Stop
    if ([int]$pp.ProxyEnable -eq 1 -and [string]$pp.ProxyServer -match '^(http=)?127\.0\.0\.1:17897$') { Set-ItemProperty -LiteralPath $ik -Name ProxyEnable -Value 0 -Type DWord; Write-Host '已关闭指向内置内核的系统代理' }
} catch {}

# 还原白羊原始配置
$cfgMsg = ''
if ($ConfigMode -eq 'Strict') {
    $mod = $null
    foreach ($c in @((Join-Path $PSScriptRoot 'BaiyangProfile.ps1'), 'C:\ProgramData\ClaudeGuard\bin\BaiyangProfile.ps1', (Join-Path $PSScriptRoot 'Config_Template\scripts\BaiyangProfile.ps1'))) { if (Test-Path -LiteralPath $c) { $mod = $c; break } }
    if ($mod) {
        try {
            . $mod
            if ((Get-BPConfigMode) -eq 'strict') { $cfgMsg = Restore-BPOriginal (Get-BPDataDir); Write-Host $cfgMsg -ForegroundColor Green }
            else { Write-Host 'Clash 配置已经是白羊原始配置，无需还原。' }
        } catch { $cfgMsg = '还原白羊原始配置失败：' + $_.Exception.Message; Write-Host $cfgMsg -ForegroundColor Yellow }
    }
}
Write-Host ''
Write-Host $(if ($engine -eq 'builtin') { '已关闭保护并停止内置内核：现在是普通直连上网。' } else { '已关闭保护并退出 Clash：现在是普通直连上网。' }) -ForegroundColor Green
Write-Host '再用 Claude 前：打开桌面「Claude保护」点「开启保护」。' -ForegroundColor Green
$fwOk = $true
try { $fwOk = -not (@(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { $_.DefaultOutboundAction -eq 'Block' }).Count -gt 0) } catch {}
if ($fwOk) { Write-ToggleResult 'off' $true $(if ($cfgMsg) { '保护已关闭，' + $cfgMsg } else { '保护已关闭' }) } else { Write-ToggleResult 'off' $false '防火墙仍处于默认拒绝，请使用「应急恢复网络」。' }
if (-not $NoPause) { Read-Host '按回车键关闭' | Out-Null }
