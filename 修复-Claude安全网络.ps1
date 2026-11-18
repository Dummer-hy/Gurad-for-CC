<#
  修复-Claude安全网络.ps1
  目标：把“Clash 节点坏了还通 / 订阅更新失败 / 换 WiFi 对不上 / 守护永远 LOCKED”一次性修到可用状态。

  它会做：
    1. 停掉 Clash Verge、白羊 App、UU 等会抢配置/抢隧道的进程
    2. 清理第二条隧道：44.0.0.0/8、114.114.114.114/32、198.16.x.x（wintun/WireGuard）
    3. 修复系统 DNS，确保 api.anthropic.com 不再解析到 44.0.0.x
    4. 写入严格版配置：单韩国节点、rule 模式、KR-ONLY、TUN mixed/1360、IPv6 关闭
    5. 部署修复后的 ClaudeGuard（内核只放行 TCP、入口端口自动跟随、DNS 全加密、第二条隧道检测）
    6. 启动 Clash、等待 TUN、验证出口必须是 KR，再加固并等待守护 OK
    7. 任何一步失败都会停在“未加固”状态，不会把你锁死在断网里

  用法：右键“以管理员身份运行”，或双击 修复-Claude安全网络.bat。
#>
param(
    [switch]$DryRun,
    [switch]$NoPause,
    [switch]$Yes,
    [int]$Mtu = 1492
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Step([string]$m) { Write-Host ''; Write-Host ('>>> ' + $m) -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host ('    [OK]   ' + $m) -ForegroundColor Green }
function Write-Warn2([string]$m){ Write-Host ('    [注意] ' + $m) -ForegroundColor Yellow }
function Write-Bad([string]$m)  { Write-Host ('    [失败] ' + $m) -ForegroundColor Red }
function Pause-Exit([int]$code) {
    if (-not $NoPause) { Write-Host ''; Read-Host '按回车键关闭窗口' | Out-Null }
    exit $code
}

# ---------------------------------------------------------------- 提权
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) {
    Write-Host '需要管理员权限，正在请求提权…' -ForegroundColor Yellow
    $a = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    if ($DryRun) { $a += ' -DryRun' }
    if ($NoPause) { $a += ' -NoPause' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $a
    exit
}

$suite     = $PSScriptRoot
$data      = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'
$guardRoot = 'C:\ProgramData\ClaudeGuard'
$guardBin  = Join-Path $guardRoot 'bin'
$ts        = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup    = Join-Path $data ("clash-verge-rev-backup\repair-$ts")
$logFile   = Join-Path $suite ("repair-$ts.log")
try { Start-Transcript -Path $logFile -Force | Out-Null } catch {}

Write-Host '======================================================================' -ForegroundColor Cyan
Write-Host '  Claude 安全网络修复：清第二条隧道 · 钉死韩国 · TUN 全局 · 守护放行' -ForegroundColor Yellow
Write-Host '======================================================================' -ForegroundColor Cyan
Write-Host @'

将要做的事：
  · 停掉 Clash Verge / 白羊 App / UU（它们会抢配置或抢 44.0.0.0/8、114.114.114.114）
  · 清理 wintun/WireGuard 残留隧道，修复系统 DNS
  · 配置改成：只保留 1 个韩国双ISP节点、rule 模式、KR-ONLY、TUN mixed/1360、IPv6 关闭、屏蔽 QUIC
  · 守护改成：内核只放行 TCP（入口端口自动跟随）、DNS 全加密、增加第二条隧道检测
  · 启动 Clash → 等 TUN → 验证出口 KR → 加固 → 等守护 OK

如果失败，会停在“未加固”状态，不会把你锁死在断网里。
'@
if (-not $DryRun -and -not $Yes) {
    $ans = Read-Host '确认执行请输入 YES（其它任意输入=取消）'
    if ($ans -ne 'YES') { Write-Host '已取消。'; Pause-Exit 0 }
}

# ---------------------------------------------------------------- 工具
function Get-VergeExe {
    $p = Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
    if ($p) { return $p.Path }
    foreach ($d in @('D:\Program Files\uu\Clash Verge', "$env:ProgramFiles\Clash Verge", "${env:ProgramFiles(x86)}\Clash Verge", (Join-Path $suite 'App'))) {
        $c = Join-Path $d 'clash-verge.exe'
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Get-DefaultInterfaceAlias {
    $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    if ($r) { return $r.InterfaceAlias }
    return $null
}

function Get-SystemDnsIp([string]$Name = 'api.anthropic.com') {
    try {
        $a = @(Resolve-DnsName $Name -Type A -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -First 1)
        if ($a) { return [string]$a.IPAddress }
    } catch {}
    return ''
}

function Test-DnsClean {
    $ip = Get-SystemDnsIp
    return [bool]($ip -and ($ip -notlike '44.0.0.*'))
}

function Get-RogueTunnelEntries {
    $bad = @()
    foreach ($r in @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        if ($r.DestinationPrefix -eq '44.0.0.0/8' -or $r.DestinationPrefix -eq '114.114.114.114/32') {
            if ($r.InterfaceAlias -match 'wintun|WireGuard' -or $r.NextHop -eq '198.16.0.1') {
                $ad = Get-NetAdapter -InterfaceIndex $r.InterfaceIndex -ErrorAction SilentlyContinue
                if (-not $ad -or $ad.Status -eq 'Up') {
                    $bad += [pscustomobject]@{ Kind='route'; Prefix=$r.DestinationPrefix; IfIndex=$r.InterfaceIndex; Alias=$r.InterfaceAlias }
                }
            }
        }
    }
    foreach ($a in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        if ($a.InterfaceAlias -notmatch 'Mihomo' -and $a.IPAddress -like '198.16.*') {
            $ad = Get-NetAdapter -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue
            if (-not $ad -or $ad.Status -eq 'Up') {
                $bad += [pscustomobject]@{ Kind='ip'; Prefix=$a.IPAddress; IfIndex=$a.InterfaceIndex; Alias=$a.InterfaceAlias }
            }
        }
    }
    # CIM 不可用时用 route print 兜底（DryRun 或系统 WMI 异常时也能检测到）
    if ($bad.Count -eq 0) {
        try {
            $rp = (& route.exe print -4 2>$null | Out-String)
            foreach ($m in [regex]::Matches($rp, '(?m)^\s*(44\.0\.0\.0|114\.114\.114\.114)\s+\S+\s+(\S+)\s+(\S+)\s+\d+')) {
                if ($m.Groups[2].Value -eq '198.16.0.1' -or $m.Groups[3].Value -like '198.16.*') {
                    $bad += [pscustomobject]@{ Kind='route'; Prefix=$m.Groups[1].Value; IfIndex=0; Alias=$m.Groups[2].Value }
                }
            }
        } catch {}
    }
    return @($bad)
}

function Test-SubUrl([string]$Url) {
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15 -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
        return ($r.StatusCode -eq 200 -and $r.Content.Length -gt 500)
    } catch { return $false }
}

function Set-ConfigRegex($Path, $Map) {
    $t = [IO.File]::ReadAllText($Path)
    foreach ($k in $Map.Keys) { $t = [regex]::Replace($t, $k, $Map[$k]) }
    [IO.File]::WriteAllText($Path, $t, (New-Object System.Text.UTF8Encoding($false)))
}

# Windows PowerShell 5.1 读无 BOM 的 UTF-8 中文脚本会乱码/解析失败；部署到 ProgramData 的副本统一加 BOM。
function Convert-ToBom([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $t = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($Path, $t, (New-Object System.Text.UTF8Encoding($true)))
}

function Get-RuntimeInfo([string]$Path) {
    $section = ''; $proxyCount = 0; $text = ''
    if (Test-Path -LiteralPath $Path) { $text = [IO.File]::ReadAllText($Path) }
    foreach ($l in ($text -split "`r?`n")) {
        if ($l -match '^([A-Za-z0-9_-]+):') { $section = $Matches[1] }
        if ($section -eq 'proxies' -and $l -match '^\s*-\s+name:') { $proxyCount++ }
    }
    return [pscustomobject]@{
        Text = $text
        ProxyCount = $proxyCount
        RuleMode = ($text -match '(?m)^mode:\s*rule')
        StrictRoute = ($text -match '(?m)^\s+strict-route:\s*true')
        KrOnly = $text.Contains('MATCH,KR-ONLY')
        UrlTest = ($text -match 'type:\s*url-test')
        TunEnable = ($text -match '(?ms)^tun:\s*\r?\n(?:.*\r?\n)*?\s+enable:\s*true')
    }
}

function Get-TraceViaProxy([string]$ProxyUrl) {
    try {
        $r = Invoke-WebRequest -Uri 'https://api.anthropic.com/cdn-cgi/trace' -Proxy $ProxyUrl -UseBasicParsing -TimeoutSec 20
        return [string]$r.Content
    } catch {}
    try {
        $p = & curl.exe -x $ProxyUrl -s -m 20 'https://api.anthropic.com/cdn-cgi/trace' 2>$null
        return ([string]$p)
    } catch {}
    return ''
}

# ---------------------------------------------------------------- 0. 环境检查
Write-Step '0/8 环境检查'
$vergeExe = Get-VergeExe
if (-not $vergeExe) { Write-Bad '找不到 clash-verge.exe'; Pause-Exit 1 }
$vergeDir = Split-Path $vergeExe -Parent
$runtimeYaml = Join-Path $data 'clash-verge.yaml'
Write-Ok "Clash Verge: $vergeExe"
if (-not (Test-Path -LiteralPath $data)) { Write-Bad "找不到数据目录 $data"; Pause-Exit 1 }
if (-not (Test-Path -LiteralPath (Join-Path $suite 'Config_Template\profiles\sRYohxTjB2to.js'))) { Write-Bad '套件缺少严格版脚本'; Pause-Exit 1 }
if (-not (Test-Path -LiteralPath (Join-Path $suite 'Config_Template\scripts\ClaudeGuard.ps1'))) { Write-Bad '套件缺少 ClaudeGuard.ps1'; Pause-Exit 1 }
Write-Ok '套件文件齐全'

if ($DryRun) {
    Write-Warn2 'DryRun：只检查，不做修改。'
    $rogue = Get-RogueTunnelEntries
    $checks = @()
    $checks += "第二条隧道条目: $($rogue.Count) 个"
    $checks += "系统 DNS: $(Get-SystemDnsIp)"
    $checks += "默认接口: $(Get-DefaultInterfaceAlias)"
    $checks | ForEach-Object { Write-Host ('    ' + $_) }
    Pause-Exit 0
}

# ---------------------------------------------------------------- 1. 停止冲突进程
Write-Step '1/8 停止 Clash Verge / 白羊 / UU'
# 旧守护可能还带着“默认拒绝出站”，先应急恢复，否则后面的订阅/启动都会被它挡住
$oldGuard = Join-Path $guardBin 'ClaudeGuard.ps1'
if (Test-Path -LiteralPath $oldGuard) {
    Write-Warn2 '检测到旧守护，先执行应急恢复（撤销默认拒绝/hosts 黑洞/防火墙规则）…'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $oldGuard -Mode Rescue 2>&1 | Out-Null
    Start-Sleep -Seconds 2
}
# 完整修复针对 Clash Verge 引擎：停掉内置内核，引擎设置改回 Clash Verge（之后可在控制台再切回内置引擎）
foreach ($t in @('ClaudeGuardCore')) { Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue; Disable-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue | Out-Null }
Get-Process -Name 'cg-mihomo' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$engFile = Join-Path $guardRoot 'engine.json'
if (Test-Path -LiteralPath $engFile) {
    try { $eng = Get-Content -LiteralPath $engFile -Raw -Encoding UTF8 | ConvertFrom-Json; if ($eng.engine -ne 'verge') { $eng.engine = 'verge'; [IO.File]::WriteAllText($engFile, ($eng | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false))); Write-Warn2 '引擎已改回 Clash Verge（完整修复只针对 Clash Verge 引擎）' } } catch {}
}
$script:stopped = 0
foreach ($n in @('clash-verge','verge-mihomo','verge-mihomo-alpha','baiyang','uu','uu_launcher','uu_agent','UUGameBooster')) {
    Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue; $script:stopped++ }
}
Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and ($_.Path -like '*\白羊加速\*' -or $_.Path -like '*\UU\*') } | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue; $script:stopped++ }
Start-Sleep -Seconds 3
Write-Ok "已停止 $script:stopped 个进程"

# ---------------------------------------------------------------- 2. 备份
Write-Step '2/8 备份配置、hosts、防火墙'
New-Item -ItemType Directory -Path (Join-Path $backup 'profiles') -Force | Out-Null
foreach ($rel in @('config.yaml','verge.yaml','profiles.yaml','clash-verge.yaml','profiles\sRYohxTjB2to.js','profiles\Script.js')) {
    $src = Join-Path $data $rel
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $backup $rel) -Force }
}
Copy-Item -LiteralPath (Join-Path $env:windir 'System32\drivers\etc\hosts') -Destination (Join-Path $backup 'hosts') -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath (Join-Path $guardRoot 'guard.config.json')) { Copy-Item -LiteralPath (Join-Path $guardRoot 'guard.config.json') -Destination (Join-Path $backup 'guard.config.json') -Force -ErrorAction SilentlyContinue }
& netsh.exe advfirewall export (Join-Path $backup 'firewall-before.wfw') 2>&1 | Out-Null
Write-Ok "备份到 $backup"

# ---------------------------------------------------------------- 3. 清理第二条隧道
Write-Step '3/8 清理第二条隧道（44.0.0.0/8 / 198.16.0.2 / 114.114.114.114）'
$rogue = @(Get-RogueTunnelEntries)
if ($rogue.Count -eq 0) {
    Write-Ok '未发现第二条隧道'
} else {
    foreach ($x in $rogue) { Write-Warn2 ("发现: {0} -> {1} ({2})" -f $x.Prefix, $x.Alias, $x.Kind) }
    $aliases = @($rogue | Where-Object { $_.Alias -match 'wintun|WireGuard' -and $_.Alias -notmatch 'Mihomo' } | ForEach-Object { $_.Alias } | Select-Object -Unique)
    foreach ($a in $aliases) {
        try { Disable-NetAdapter -Name $a -Confirm:$false -ErrorAction Stop; Write-Ok "已禁用网卡 $a" } catch { Write-Warn2 ("禁用网卡 {0} 失败：{1}" -f $a, $_.Exception.Message) }
    }
    foreach ($x in @($rogue | Where-Object { $_.Kind -eq 'route' })) {
        try { Remove-NetRoute -DestinationPrefix $x.Prefix -InterfaceIndex $x.IfIndex -Confirm:$false -ErrorAction Stop; Write-Ok "已删除路由 $($x.Prefix)" } catch { Write-Warn2 ("删除路由 {0} 失败：{1}" -f $x.Prefix, $_.Exception.Message) }
    }
    Start-Sleep -Seconds 2
    $left = @(Get-RogueTunnelEntries)
    if ($left.Count -gt 0) {
        Write-Bad ('第二条隧道仍然存在：' + (($left | ForEach-Object { "$($_.Prefix)->$($_.Alias)" }) -join '; '))
        Write-Warn2 '请手动退出白羊/UU，或在设备管理器禁用 wintun 网卡后重跑本脚本。'
        Pause-Exit 1
    }
    Write-Ok '第二条隧道已清理'
}

# ---------------------------------------------------------------- 4. 修复 DNS
Write-Step '4/8 修复系统 DNS'
Clear-DnsClientCache
ipconfig /flushdns 2>&1 | Out-Null
Start-Sleep -Seconds 2
if (-not (Test-DnsClean)) {
    $alias = Get-DefaultInterfaceAlias
    if ($alias) {
        $origFile = Join-Path $guardRoot 'state\net-original.json'
        if (-not (Test-Path -LiteralPath $origFile)) {
            $cur = @((Get-DnsClientServerAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
            $isDhcp = $true
            try { $isDhcp = ((Get-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction Stop).Dhcp -eq 'Enabled') } catch {}
            $regDns = ''
            try { $guid = (Get-NetAdapter -Name $alias -ErrorAction Stop).InterfaceGuid; $regDns = [string](Get-ItemProperty -Path ("HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\" + $guid) -Name NameServer -ErrorAction Stop).NameServer } catch {}
            New-Item -ItemType Directory -Path (Split-Path $origFile) -Force | Out-Null
            [IO.File]::WriteAllText($origFile, ([ordered]@{ alias = $alias; staticDns = $regDns; current = $cur; dhcp = $isDhcp } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
        }
        Write-Warn2 "系统 DNS 仍被接管（api.anthropic.com -> $(Get-SystemDnsIp)），临时改用 223.5.5.5/119.29.29.29（关闭保护时自动还原）"
        try { Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses @('223.5.5.5','119.29.29.29') -ErrorAction Stop } catch { Write-Warn2 ("设置 DNS 失败：{0}" -f $_.Exception.Message) }
        Clear-DnsClientCache
        ipconfig /flushdns 2>&1 | Out-Null
        Start-Sleep -Seconds 2
    }
}
if (-not (Test-DnsClean)) {
    Write-Bad ("DNS 仍异常：api.anthropic.com -> {0}" -f (Get-SystemDnsIp))
    Write-Warn2 '请确认 wintun 网卡已禁用、没有其他 VPN 在跑。'
    Pause-Exit 1
}
Write-Ok ("DNS 正常：api.anthropic.com -> {0}" -f (Get-SystemDnsIp))

# ---------------------------------------------------------------- 4.5 网卡 MTU（外层 TCP MSS）
# TUN 的 1360 只管内层；Clash 到日本入口的外层 TCP MSS 仍按物理网卡 MTU 计算。
# PPPoE 宽带常见 1492；不降到 1492 时，外层大包可能被丢，表现为 3 秒 RTO、偶发卡顿。
Write-Step '4.5/8 设置活动网卡 MTU（修复外层大包被截断）'
$mtuAlias = Get-DefaultInterfaceAlias
if (-not $mtuAlias) {
    Write-Warn2 '未找到默认接口，跳过 MTU 设置'
} else {
    $mtuCur = $null
    try { $mtuCur = (Get-NetIPInterface -InterfaceAlias $mtuAlias -AddressFamily IPv4 -ErrorAction Stop).NlMtu } catch {}
    if ($mtuCur -eq $Mtu) {
        Write-Ok "网卡 $mtuAlias MTU 已是 $Mtu"
    } else {
        & netsh.exe interface ipv4 set subinterface "$mtuAlias" mtu=$Mtu store=persistent 2>&1 | Out-Null
        Start-Sleep -Seconds 1
        $mtuNew = $null
        try { $mtuNew = (Get-NetIPInterface -InterfaceAlias $mtuAlias -AddressFamily IPv4 -ErrorAction Stop).NlMtu } catch {}
        if ($mtuNew -eq $Mtu) {
            Write-Ok "网卡 $mtuAlias MTU：$mtuCur -> $mtuNew"
        } else {
            Write-Warn2 "网卡 $mtuAlias MTU 设置未确认（当前 $mtuNew，目标 $Mtu）"
        }
    }
}

# ---------------------------------------------------------------- 5. 写入严格配置
Write-Step '5/8 写入严格配置（单韩国节点 / rule / KR-ONLY / TUN）'
if (-not (Test-Path -LiteralPath $data)) { Write-Bad "数据目录不存在：$data"; Pause-Exit 1 }
$cfgPath = Join-Path $data 'config.yaml'
$vpPath  = Join-Path $data 'verge.yaml'
$ppPath  = Join-Path $data 'profiles.yaml'
if (-not (Test-Path -LiteralPath $cfgPath) -or -not (Test-Path -LiteralPath $vpPath) -or -not (Test-Path -LiteralPath $ppPath)) {
    Write-Bad '缺少 config.yaml / verge.yaml / profiles.yaml，请先启动一次 Clash Verge 生成。'
    Pause-Exit 1
}

# 锁定节点：沿用「Claude 保护」里选的节点（没选过 = 韩国双ISP）
. (Join-Path $suite 'Config_Template\scripts\BaiyangProfile.ps1')
$pin = Get-BPPinnedNode
$expectCountry = $(if ($pin.country) { $pin.country } else { 'KR' })
[IO.File]::WriteAllText((Join-Path $data 'profiles\sRYohxTjB2to.js'), (Get-BPRenderedJs $pin), (New-Object System.Text.UTF8Encoding($false)))
Write-Ok ("已写入严格版 sRYohxTjB2to.js（锁定节点：{0} · 期望出口 {1}）" -f $pin.name, $expectCountry)

Set-ConfigRegex $cfgPath ([ordered]@{
    '(?m)^mode:\s*\S+'                    = 'mode: rule'
    '(?m)^ipv6:\s*\S+'                    = 'ipv6: false'
    '(?m)^allow-lan:\s*\S+'               = 'allow-lan: false'
    '(?m)^log-level:\s*\S+'               = 'log-level: warning'
    '(?m)^(\s+mtu:\s*)\d+'                = '${1}1360'
    '(?m)^(\s+stack:\s*)\S+'              = '${1}mixed'
    '(?m)^(\s+strict-route:\s*)\S+'       = '${1}true'
    '(?m)^(\s+route-exclude-address:\s*).*$' = '${1}[]'
})
Write-Ok 'config.yaml：mode=rule, ipv6=false, mtu=1360, mixed, strict-route=true'

Set-ConfigRegex $vpPath ([ordered]@{
    '(?m)^enable_tun_mode:\s*\S+'        = 'enable_tun_mode: true'
    '(?m)^enable_system_proxy:\s*\S+'    = 'enable_system_proxy: false'
    '(?m)^default_latency_timeout:\s*\S+' = 'default_latency_timeout: 10000'
    '(?m)^startup_script:.*$'            = 'startup_script: null'
    '(?m)^  ip: true$'                   = '  ip: false'
    '(?m)^  test: true$'                 = '  test: false'
    '(?m)^auto_check_update: true$'      = 'auto_check_update: false'
    '(?m)^enable_auto_delay_detection:.*$' = 'enable_auto_delay_detection: false'
})
Write-Ok 'verge.yaml：TUN=true, 系统代理=false, IP/Test 卡片关闭, 自动更新关闭'

# 订阅地址：写死 bnet；不再做直连探测（修复阶段也不允许直连国内）
$pt = [IO.File]::ReadAllText($ppPath)
$m = [regex]::Match($pt, '(?m)^\s+url:\s*(\S+)')
$oldUrl = if ($m.Success) { $m.Groups[1].Value } else { '' }
$mt = [regex]::Match($oldUrl, '^https?://([^/]+)/baiyang/api/([^?]+)')
if (-not $mt.Success) {
    Write-Bad 'profiles.yaml 里找不到白羊订阅地址（/baiyang/api/<token>），请先在 Clash Verge 里导入一次白羊订阅。'
    Pause-Exit 1
}
# 保留官方当前使用的订阅域名（官方会换域名，不再强制改回旧域名）
$subHost = $mt.Groups[1].Value
$token = $mt.Groups[2].Value
$subUrl = ("https://{0}/baiyang/api/{1}?flag=meta" -f $subHost, $token)
$subUrlMasked = ("https://{0}/baiyang/api/***?flag=meta" -f $subHost)
$pt = [regex]::Replace($pt, '(?m)^(\s+url:\s*).*$', ('${1}' + $subUrl))
$pt = [regex]::Replace($pt, '(?m)^(\s+update_interval:\s*)\d+', '${1}30')
$pt = [regex]::Replace($pt, '(?m)^(\s+with_proxy:\s*)\S+', '${1}true')
[IO.File]::WriteAllText($ppPath, $pt, (New-Object System.Text.UTF8Encoding($false)))
Write-Ok "profiles.yaml：url=$subUrlMasked, update_interval=30（订阅域名由内核直连，入口端口变了也能自动拉到新订阅）"

# ---------------------------------------------------------------- 6. 部署守护
Write-Step '6/8 部署修复后的 ClaudeGuard'
New-Item -ItemType Directory -Path $guardBin -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $suite 'Config_Template\scripts\ClaudeGuard.ps1') -Destination (Join-Path $guardBin 'ClaudeGuard.ps1') -Force
# 先退出正在运行的托盘程序，再替换文件
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'SecurityHub\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Process -Name 'cg-hub' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Copy-Item -LiteralPath (Join-Path $suite 'Config_Template\scripts\SecurityHub.ps1') -Destination (Join-Path $guardBin 'SecurityHub.ps1') -Force
Copy-Item -LiteralPath (Join-Path $suite 'Config_Template\scripts\ClaudeHub.vbs') -Destination (Join-Path $guardBin 'ClaudeHub.vbs') -Force
foreach ($pair in @(@('Rescue-恢复网络.ps1','Rescue.ps1'), @('Resume-恢复保护.ps1','Resume.ps1'), @('Pause-关闭保护.ps1','Pause.ps1'),
                    @('Config_Template\scripts\BaiyangProfile.ps1','BaiyangProfile.ps1'), @('Config_Template\scripts\Refresh-Subscription.ps1','Refresh-Subscription.ps1'),
                    @('Config_Template\scripts\BuiltinCore.ps1','BuiltinCore.ps1'), @('Config_Template\scripts\NetMonitor.ps1','NetMonitor.ps1'), @('Switch-热切换.ps1','Switch.ps1'),
                    @('Config_Template\profiles\sRYohxTjB2to.js','strict-profile.js'), @('Config_Template\scripts\cg-guard.exe','cg-guard.exe'),
                    @('Config_Template\scripts\cg-hub.exe','cg-hub.exe'), @('Config_Template\scripts\HubData.ps1','HubData.ps1'))) {
    $src = Join-Path $suite $pair[0]
    if ($pair[1] -eq 'cg-guard.exe') { Get-Process -Name 'cg-guard' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 300 }
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $guardBin $pair[1]) -Force }
}
foreach ($f in @('ClaudeGuard.ps1','SecurityHub.ps1','Rescue.ps1','Resume.ps1','Pause.ps1','BaiyangProfile.ps1','BuiltinCore.ps1','NetMonitor.ps1','Refresh-Subscription.ps1','Switch.ps1','HubData.ps1')) { Convert-ToBom (Join-Path $guardBin $f) }

$globs = @(
    (Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe'),
    (Join-Path $env:LOCALAPPDATA 'AnthropicClaude\app-*\claude.exe'),
    (Join-Path $env:APPDATA 'Claude\claude-code\*\*\claude.exe'),
    (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Antigravity*\Antigravity*.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Claude*\*.exe')
)
$byangDir = 'D:\Program Files\uu\白羊加速'
$deny = @()
if (Test-Path -LiteralPath $byangDir) { $deny = @((Join-Path $byangDir '*')) }
$cfgObj = [ordered]@{
    coreRoots          = @($vergeDir)
    runtimeYaml        = $runtimeYaml
    claudeProgramGlobs = $globs
    denyCorePathLike   = $deny
    probeProxy         = ''
    extraAllowPrograms = @()
    probeIntervalSec   = 300
    probeRetrySec      = 60
    probeTimeoutSec    = 15
    hardRecoverTicks   = 3
    recoverThreshold   = 2
    expectedCountry    = $expectCountry
    allowedAsns        = $(if ($expectCountry -eq 'KR') { @(401783) } else { @() })
    strictAsn          = $false
    tunAlias           = 'Mihomo'
    tunLocalCidr       = '198.18.0.0/24'
}
[IO.File]::WriteAllText((Join-Path $guardRoot 'guard.config.json'), ($cfgObj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
# 记录套件文件夹位置：控制台据此检测新版本、执行更新/完整修复
[IO.File]::WriteAllText((Join-Path $guardRoot 'suite.json'), ([ordered]@{ path = $suite } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
& icacls.exe $guardRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' 2>&1 | Out-Null
& icacls.exe (Join-Path $guardRoot 'commands') /grant '*S-1-5-32-545:(OI)(CI)M' 2>&1 | Out-Null
Write-Ok '守护已部署，guard.config.json 已更新'

# ---------------------------------------------------------------- 7. 启动并验证
Write-Step '7/8 启动 Clash、等待 TUN、验证出口 KR'
$oldCoreIds = @(Get-Process -Name 'verge-mihomo','verge-mihomo-alpha' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
Start-Process explorer.exe -ArgumentList ('"{0}"' -f $vergeExe)
$tunUp = $false; $pinned = $false; $info = $null
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 2
    $ad = Get-NetAdapter -Name 'Mihomo' -ErrorAction SilentlyContinue
    $tunUp = [bool]($ad -and $ad.Status -eq 'Up')
    $info = Get-RuntimeInfo $runtimeYaml
    $pinned = ($info.ProxyCount -eq 1 -and $info.RuleMode -and $info.StrictRoute -and $info.KrOnly -and -not $info.UrlTest)
    if ($tunUp -and $pinned) { break }
}
if (-not $tunUp) {
    Write-Bad 'TUN 未起来。请检查 Clash Verge 是否以服务模式运行、界面里 TUN 开关是否打开。'
    Pause-Exit 1
}
if (-not $pinned) {
    Write-Bad ("运行配置未钉死：proxyCount={0} rule={1} strict={2} KR-ONLY={3} url-test={4}" -f $info.ProxyCount, $info.RuleMode, $info.StrictRoute, $info.KrOnly, $info.UrlTest)
    Write-Warn2 ("常见原因：订阅里没有锁定的节点「{0}」，或 Verge 还没重新加载配置。" -f $pin.name)
    Pause-Exit 1
}
Write-Ok 'TUN 已启动，运行配置：1 个节点 / rule / strict-route / KR-ONLY'

$trace = ''
for ($t = 1; $t -le 6 -and -not $trace; $t++) {
    $trace = Get-TraceViaProxy 'http://127.0.0.1:7897'
    if (-not $trace) { Write-Warn2 ("第 {0}/6 次出口探测失败（节点偶发超时），3 秒后重试…" -f $t); Start-Sleep -Seconds 3 }
}
if (-not $trace) {
    Write-Bad '经 7897 探测失败：Clash 没在监听或节点不可用。'
    Pause-Exit 1
}
$loc = ''; $ip = ''
if ($trace -match '(?m)^loc=([A-Za-z]{2})') { $loc = $Matches[1].ToUpperInvariant() }
if ($trace -match '(?m)^ip=(\S+)') { $ip = $Matches[1] }
if ($loc -ne $expectCountry) {
    Write-Bad ("出口不是期望的 {0}：loc={1} ip={2}" -f $expectCountry, $loc, $ip)
    Write-Warn2 ("请确认订阅里仍有锁定的节点「{0}」，且没有被换掉。" -f $pin.name)
    Pause-Exit 1
}
Write-Ok ("出口验证通过：{0} ({1})" -f $ip, $loc)

# ---------------------------------------------------------------- 8. 加固 + 守护
Write-Step '8/8 加固防火墙并等待守护放行'
$guardScript = Join-Path $guardBin 'ClaudeGuard.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $guardScript -Mode Harden
if ($LASTEXITCODE -ne 0) {
    Write-Bad '加固失败（守护应已自动回滚防火墙）。详见 C:\ProgramData\ClaudeGuard\logs\guard.log'
    Pause-Exit 1
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $guardScript -Mode Install
$stateFile = Join-Path $guardRoot 'state\guard_state.json'
$ok = $false; $state = $null
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 2
    if (Test-Path -LiteralPath $stateFile) {
        try { $state = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if ($state.mode -eq 'OK') { $ok = $true; break }
    }
}
if ($ok) {
    Write-Ok ("守护 OK · 出口 {0} ({1})" -f $state.identity.ip, $state.identity.country)
} else {
    $why = ''; if ($state) { $why = [string]$state.reason }
    Write-Bad ("守护未进入 OK：{0}" -f $why)
    if ($state) { $state.checks | Where-Object { -not $_.ok } | ForEach-Object { Write-Warn2 ("{0}: {1}" -f $_.title, $_.detail) } }
    Write-Warn2 '为避免把你锁在断网里，正在执行应急恢复…'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $guardScript -Mode Rescue
    Pause-Exit 1
}

# ---------------------------------------------------------------- 快捷方式
try {
    $wsh = New-Object -ComObject WScript.Shell
    $desk = [Environment]::GetFolderPath('Desktop')
    $s1 = $wsh.CreateShortcut((Join-Path $desk 'Claude保护.lnk'))
    $s1.TargetPath = Join-Path $env:windir 'System32\wscript.exe'
    $s1.Arguments = ('"{0}"' -f (Join-Path $guardBin 'ClaudeHub.vbs'))
    $s1.IconLocation = "$env:windir\System32\imageres.dll,102"
    $s1.Description = 'Claude 保护开关：开启=放心使用 Claude；关闭=正常上网'
    $s1.Save()
    # 更新 / 完整修复 / 应急恢复 都在控制台里；桌面只留「Claude保护」
    foreach ($n in @('Claude保护-更新.lnk', 'Claude保护-一键升级.lnk', '应急恢复网络.lnk')) {
        $p = Join-Path $desk $n; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }
    # 保底：开始菜单保留「应急恢复网络」（控制台本身打不开时用）
    $sm = Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude保护'
    New-Item -ItemType Directory -Path $sm -Force | Out-Null
    $s2 = $wsh.CreateShortcut((Join-Path $sm '应急恢复网络.lnk'))
    $s2.TargetPath = 'powershell.exe'
    $s2.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $guardBin 'Rescue.ps1'))
    $s2.IconLocation = "$env:windir\System32\imageres.dll,100"
    $s2.Description = '应急：立即恢复默认网络（控制台打不开时使用）'
    $s2.Save()
    $s3 = $wsh.CreateShortcut((Join-Path $sm 'Claude保护.lnk'))
    $s3.TargetPath = Join-Path $env:windir 'System32\wscript.exe'
    $s3.Arguments = ('"{0}"' -f (Join-Path $guardBin 'ClaudeHub.vbs'))
    $s3.IconLocation = "$env:windir\System32\imageres.dll,102"
    $s3.Save()
    Write-Ok '桌面「Claude保护」已就绪；更新 / 完整修复 / 应急恢复都在控制台里（开始菜单另有应急恢复保底）'
} catch { Write-Warn2 ("快捷方式创建失败：{0}" -f $_.Exception.Message) }

Write-Host ''
Write-Host '======================================================================' -ForegroundColor Green
Write-Host '  修复完成。' -ForegroundColor Green
Write-Host '  · 现在 Claude 走 Clash 的韩国双ISP节点，TUN 全局接管，守护已放行。' -ForegroundColor Green
Write-Host '  · 使用 Claude 期间不要再打开白羊 App / UU，它们会重新插入 wintun 隧道。' -ForegroundColor Yellow
Write-Host '  · 订阅每 30 分钟自动更新；出口检测连续失败时控制台会自动检查订阅，入口端口变了自动跟随。' -ForegroundColor Green
Write-Host '  · 开启保护：自动拉订阅并套用严格配置；关闭保护：自动恢复白羊原始配置（控制台「配置模式」可改）。' -ForegroundColor Green
Write-Host '  · 日常只用桌面「Claude保护」：开关保护、更新订阅、更新到最新版、完整修复、应急恢复都在里面。' -ForegroundColor Green
Write-Host ("  · 备份：{0}" -f $backup) -ForegroundColor DarkGray
Write-Host ("  · 日志：{0}" -f $logFile) -ForegroundColor DarkGray
Write-Host '======================================================================' -ForegroundColor Green
try { Start-Process explorer.exe -ArgumentList ('"{0}"' -f (Join-Path $guardBin 'ClaudeHub.vbs')) } catch {}
try { Stop-Transcript | Out-Null } catch {}
Pause-Exit 0
