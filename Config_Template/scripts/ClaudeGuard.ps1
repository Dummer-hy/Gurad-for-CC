<#
.SYNOPSIS
  Claude 零泄露守护进程（Windows PowerShell 5.1 兼容）

.DESCRIPTION
  设计原则：只允许「断开」，不允许「回落直连」。

  第一层 · 默认拒绝（Harden）
    把 Windows 防火墙出站默认动作改为 Block，仅放行：
      · 源地址属于 TUN 网卡（198.18.0.0/24）的流量 —— 即所有进入 Mihomo 的流量
      · Mihomo 内核自身（只允许中继 28000 端口 + 解析中继域名的 DNS）
      · 局域网 / DHCP
    同时用 Block 规则（Block 优先于任何 Allow）封死：
      · 全部全球单播 IPv6（2000::/3），并解绑物理网卡的 IPv6
    DNS 由 TUN 的 dns-hijack 接管；内核只允许中继 28000 和解析中继域名的 53，其余默认拒绝。
    结果：TUN 一旦掉线 / 内核退出，除内核外所有程序立即断网，没有回落路径。

  第二层 · 看门狗（Run）
    每 2 秒做本地体检（不联网）；出口探针低频运行：正常每 5 分钟一次，失败后每 1 分钟重试。
      · 硬故障（内核/TUN/路由/防火墙基线/第二条隧道/系统 DNS 被 44.0.0.0/8 接管）→ 立即封锁，
        本地体检连续 3 次（约 6 秒）恢复正常即自动解除
      · 探针失败/超时 → 只记录、不封锁。节点慢或被限流不等于泄露：防泄露靠防火墙默认拒绝 + TUN，
        节点不通时流量本来就出不去
      · 探针确认出口国家错误（成功拿到 loc 且 != KR）或手动强制 → 整机断网，需探针确认 KR 才恢复
      · 封锁时同时：hosts 黑洞 AI 域名 + 启用 Claude 程序出站 Block 规则

  第三层 · 应急（Rescue）
    任何时候可执行 -Mode Rescue 一键恢复默认网络（见 Rescue-恢复网络.bat）。

.PARAMETER Mode
  Run | Once | Harden | Rescue(暂停保护) | Resume(恢复保护) | Install | Uninstall | Status | Audit
.PARAMETER DryRun
  只检查与记录，不修改系统（hosts / 防火墙 / 网卡绑定 / 计划任务）。
.PARAMETER Root
  数据目录，默认 C:\ProgramData\ClaudeGuard。
#>
param(
    # 7.0 起常驻守护由 Rust 版 cg-guard.exe 承担；本脚本负责加固/应急/安装，
    # 并提供 SyncBaseline 等模式，供 cg-guard 委托执行少数“改防火墙规则结构”的操作
    [ValidateSet('Run','Once','Harden','Rescue','Resume','Install','Uninstall','Status','Audit',
                 'SyncBaseline','SyncClaude','SyncIpv6','SetTunAllow','StartCore','ReloadCore','RegisterTask')]
    [string]$Mode = 'Run',
    [switch]$DryRun,
    [string]$Root = 'C:\ProgramData\ClaudeGuard',
    [switch]$Quiet,
    [switch]$CutAll,      # SyncBaseline：整机断网中，同步时不重新启用 TUN 放行
    [switch]$Enable,      # SyncClaude / SetTunAllow：启用
    [switch]$NoEnable     # SyncClaude / SetTunAllow：停用
)

$ErrorActionPreference = 'Stop'
$script:Version   = '6.4'
$script:RuleGroup = 'ClaudeGuard'
$script:TaskName  = 'ClaudeGuard'
$script:LogDir    = Join-Path $Root 'logs'
$script:LogFile   = Join-Path $script:LogDir 'guard.log'
$script:StateDir  = Join-Path $Root 'state'
$script:StateFile = Join-Path $script:StateDir 'guard_state.json'
$script:CmdDir    = Join-Path $Root 'commands'
$script:CmdFile   = Join-Path $script:CmdDir 'cmd.json'
$script:CfgFile   = Join-Path $Root 'guard.config.json'
$script:RescueFile= Join-Path $Root 'rescue-state.json'
$script:SwitchFile= Join-Path $script:StateDir 'switching.json'        # 热切换进行中（仅管理员可写）
$script:ProgressFile = Join-Path $script:StateDir 'switch-progress.json'
$script:HostsPath = Join-Path $env:windir 'System32\drivers\etc\hosts'
$script:HostsBegin= '# >>> ClaudeGuard BEGIN (自动生成，请勿手动编辑)'
$script:HostsEnd  = '# <<< ClaudeGuard END'

# ----------------------------------------------------------------------
# 配置
# ----------------------------------------------------------------------
function Get-DefaultConfig {
    return [ordered]@{
        expectedCountry   = 'KR'
        allowedAsns       = @(401783)
        strictAsn         = $false
        engine            = 'verge'      # verge = 借用 Clash Verge；builtin = Claude保护 自带内核（core\cg-mihomo.exe）
        netMode           = 'tun'        # tun / sysproxy（仅内置引擎）
        coreDiscovery     = $true        # 是否自动发现正在运行的 Clash 内核并放行；内置引擎只放行自己的内核
        tunAlias          = 'Mihomo'
        tunLocalCidr      = '198.18.0.0/24'
        fakeIpCidrStart   = '198.18.0.0'
        coreRoots         = @('D:\Program Files\uu\Clash Verge')
        coreNames         = @('verge-mihomo.exe','verge-mihomo-alpha.exe')
        denyCorePathLike  = @()
        probeProxy        = ''
        extraAllowPrograms= @()
        runtimeYaml       = ''
        probeIntervalSec  = 300       # 正常时出口探针间隔（秒）
        probeRetrySec     = 60        # 探针失败后的重试间隔（秒）；失败不封锁
        probeTimeoutSec   = 15
        asnRefreshSec     = 21600     # ASN 查询（ipwho.is 有频率限制）：仅首次 / IP 变化 / 每 6 小时一次
        hardRecoverTicks  = 3         # 硬故障解除需连续正常的本地体检次数（每次约 2 秒）
        recoverThreshold  = 2         # 国家错误断网后，需连续确认 KR 的探针次数
        probeUrls         = @('https://api.anthropic.com/cdn-cgi/trace','https://www.cloudflare.com/cdn-cgi/trace','https://1.1.1.1/cdn-cgi/trace')
        ipv6Unbind        = $true
        blackholeDomains  = @(
            'claude.ai','www.claude.ai','api.claude.ai','claude.com','www.claude.com',
            'anthropic.com','www.anthropic.com','api.anthropic.com','console.anthropic.com',
            'docs.anthropic.com','statsig.anthropic.com','claude.usercontent.com','claudeusercontent.com',
            'chatgpt.com','www.chatgpt.com','chat.openai.com','api.openai.com','auth.openai.com',
            'openai.com','www.openai.com',
            'gemini.google.com','aistudio.google.com','generativelanguage.googleapis.com'
        )
        claudeProgramGlobs= @()
    }
}

function Get-Config([switch]$Strict) {
    # -Strict：配置文件读不出来时返回 $null（运行中重新加载用，避免文件正被改写时退回默认值）
    $cfg = Get-DefaultConfig
    if (Test-Path -LiteralPath $script:CfgFile) {
        try {
            $j = Get-Content -LiteralPath $script:CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
        } catch {
            if ($Strict) { return $null }
            Write-Log "配置文件解析失败，使用默认值：$($_.Exception.Message)" 'WARN'
        }
    }
    return $cfg
}

function Get-CfgStamp { try { return (Get-Item -LiteralPath $script:CfgFile -ErrorAction Stop).LastWriteTimeUtc.Ticks } catch { return 0L } }

# ----------------------------------------------------------------------
# 基础设施：日志 / 变更封装 / 权限
# ----------------------------------------------------------------------
function Write-Log([string]$Msg, [string]$Level = 'INFO') {
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg
    if (-not $Quiet) { Write-Host $line }
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
        if ((Test-Path -LiteralPath $script:LogFile) -and ((Get-Item -LiteralPath $script:LogFile).Length -gt 2MB)) {
            Move-Item -LiteralPath $script:LogFile -Destination ($script:LogFile + '.1') -Force
        }
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    } catch {}
}

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Mut([string]$Desc, [scriptblock]$Block) {
    if ($DryRun) { Write-Log "[DRY] $Desc" 'DRY'; return $true }
    try { & $Block; return $true }
    catch { Write-Log "$Desc 失败：$($_.Exception.Message)" 'ERROR'; return $false }
}

function Ensure-Dirs {
    foreach ($d in @($Root, $script:LogDir, $script:StateDir, $script:CmdDir)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    if (-not $DryRun -and (Test-Admin)) {
        # Root: 管理员/SYSTEM 完全控制，普通用户只读；commands 目录普通用户可写（只能下发“更严”的指令）
        & icacls.exe $Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' 2>&1 | Out-Null
        & icacls.exe $script:CmdDir /grant '*S-1-5-32-545:(OI)(CI)M' 2>&1 | Out-Null
    }
}

# ----------------------------------------------------------------------
# 路径发现
# ----------------------------------------------------------------------
function Get-CorePaths($cfg) {
    $set = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $cfg.coreRoots) {
        foreach ($n in $cfg.coreNames) {
            $p = Join-Path $r $n
            if ([IO.File]::Exists($p)) { [void]$set.Add($p) }
        }
    }
    # 内置引擎：只放行自己的内核文件，绝不自动放行电脑上其他 Clash 的内核（它们即使运行也连不出去）
    if (-not $cfg.coreDiscovery) {
        foreach ($p in $cfg.extraAllowPrograms) { if ($p) { [void]$set.Add($p) } }
        return @($set)
    }
    # Clash Verge 服务模式从这里运行内核：固定放行（不依赖进程发现，守护重启/升级时规则不会被误删）
    foreach ($n in $cfg.coreNames) {
        $p = Join-Path 'C:\ProgramData\clash-verge-service\cores' $n
        if ([IO.File]::Exists($p)) { [void]$set.Add($p) }
    }
    try {
        foreach ($proc in Get-CimInstance Win32_Process -Filter "Name LIKE 'verge-mihomo%'" -ErrorAction Stop) {
            $p = $proc.ExecutablePath
            if (-not $p) { continue }
            $denied = $false
            foreach ($pat in $cfg.denyCorePathLike) { if ($p -like $pat) { $denied = $true } }
            if ($denied) { continue }
            [void]$set.Add($p)
        }
    } catch {}
    # 兜底：从正在运行的 Clash Verge 目录发现内核，避免 coreRoots 写死/换安装位置后找不到
    try {
        $cv = Get-Process -Name 'clash-verge' -ErrorAction Stop | Where-Object { $_.Path } | Select-Object -First 1
        if ($cv) {
            $d = Split-Path $cv.Path -Parent
            foreach ($n in $cfg.coreNames) {
                $p = Join-Path $d $n
                if ([IO.File]::Exists($p)) { [void]$set.Add($p) }
            }
        }
    } catch {}
    foreach ($p in $cfg.extraAllowPrograms) { if ($p) { [void]$set.Add($p) } }
    return @($set)
}

function Get-ClaudePrograms($cfg) {
    $found = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($g in $cfg.claudeProgramGlobs) {
        if (-not $g) { continue }
        try { foreach ($f in Get-ChildItem -Path $g -File -ErrorAction SilentlyContinue) { [void]$found.Add($f.FullName) } } catch {}
    }
    return @($found)
}

# ----------------------------------------------------------------------
# 防火墙：基线 / 封锁规则
# ----------------------------------------------------------------------
function New-GuardRule([hashtable]$Params) {
    $p = @{ Group = $script:RuleGroup; Profile = 'Any'; Enabled = 'True' }
    foreach ($k in $Params.Keys) { $p[$k] = $Params[$k] }
    New-NetFirewallRule @p | Out-Null
}

# ---------- 快速状态读取（毫秒级；NetSecurity/CIM 系列 cmdlet 在 5.1 下每次 0.8~1.2 秒，仅在需要修复/复核时才调用）----------
$script:FwRulesKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules'
$script:CoreCache  = @{ t = [DateTime]::MinValue; v = @() }
$script:RtCache    = @{ mtime = [DateTime]::MinValue; res = @() }
$script:PolCache   = @{ t = [DateTime]::MinValue; v = @() }
$script:RogueCache = @{ t = [DateTime]::MinValue; v = @() }
$script:DnsCache   = @{ t = [DateTime]::MinValue; v = '' }

function Get-CorePathsCached($cfg) {
    if (((Get-Date) - $script:CoreCache.t).TotalSeconds -gt 60) { $script:CoreCache.v = @(Get-CorePaths $cfg); $script:CoreCache.t = Get-Date }
    return $script:CoreCache.v
}

# 返回 name -> Active(bool)，只含 ClaudeGuard-* 规则
function Get-GuardRuleStateFast {
    $map = @{}
    try {
        $k = Get-Item -LiteralPath $script:FwRulesKey -ErrorAction Stop
        foreach ($n in $k.GetValueNames()) {
            if ($n -like 'ClaudeGuard-*') { $map[$n] = ([string]$k.GetValue($n) -match '\|Active=TRUE(\||$)') }
        }
    } catch {}
    return $map
}

# 返回三个配置文件（域/专用/公用）的出站默认动作：'Block' / 'Allow'。netsh 输出里的关键字不受系统语言影响。
function Get-OutboundPolicy([bool]$Force = $false) {
    if (-not $Force -and ((Get-Date) - $script:PolCache.t).TotalSeconds -lt 8) { return $script:PolCache.v }
    $o = (& netsh.exe advfirewall show allprofiles firewallpolicy 2>&1 | Out-String)
    $v = @([regex]::Matches($o, '(Allow|Block)Inbound,(Allow|Block)Outbound') | ForEach-Object { $_.Groups[2].Value })
    $script:PolCache.v = $v; $script:PolCache.t = Get-Date
    return $v
}

# 第二条隧道检测：44.0.0.0/8、114.114.114.114/32、198.16.x.x 会抢在 Clash TUN 前面接管 DNS/流量。
# 典型来源：白羊 App 的加速层、UU/其他 WireGuard 客户端残留。Mihomo 自己用 198.18.0.1，不会误判。
function Get-RogueTunnelInfo {
    if (((Get-Date) - $script:RogueCache.t).TotalSeconds -lt 30) { return $script:RogueCache.v }
    $bad = @(); $cimOk = $true
    try {
        foreach ($r in @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop)) {
            if ($r.DestinationPrefix -eq '44.0.0.0/8' -or $r.DestinationPrefix -eq '114.114.114.114/32') {
                if ($r.InterfaceAlias -match 'wintun|WireGuard' -or $r.NextHop -eq '198.16.0.1') {
                    $ad = Get-NetAdapter -InterfaceIndex $r.InterfaceIndex -ErrorAction SilentlyContinue
                    if (-not $ad -or $ad.Status -eq 'Up') { $bad += ('路由 {0} -> {1}' -f $r.DestinationPrefix, $r.InterfaceAlias) }
                }
            }
        }
        foreach ($a in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop)) {
            if ($a.InterfaceAlias -notmatch 'Mihomo' -and $a.IPAddress -like '198.16.*') {
                $ad = Get-NetAdapter -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue
                if (-not $ad -or $ad.Status -eq 'Up') { $bad += ('网卡 {0} {1}' -f $a.InterfaceAlias, $a.IPAddress) }
            }
        }
    } catch { $cimOk = $false }
    # 只有 CIM 不可用时才用 route print/ipconfig 兜底（正常情况下不再每轮都跑外部程序）
    if (-not $cimOk) {
        try {
            $rp = (& route.exe print -4 2>$null | Out-String)
            foreach ($m in [regex]::Matches($rp, '(?m)^\s*(44\.0\.0\.0|114\.114\.114\.114)\s+\S+\s+(\S+)\s+(\S+)\s+\d+')) {
                if ($m.Groups[2].Value -eq '198.16.0.1' -or $m.Groups[3].Value -like '198.16.*') {
                    $bad += ('路由 {0} -> {1}' -f $m.Groups[1].Value, $m.Groups[2].Value)
                }
            }
            $ipc = (& ipconfig 2>$null | Out-String)
            if ($ipc -match '198\.16\.\d+\.\d+') { $bad += '存在 198.16.x.x 地址' }
        } catch {}
    }
    $bad = @($bad | Select-Object -Unique)
    $script:RogueCache.v = $bad; $script:RogueCache.t = Get-Date
    return $bad
}

# 系统 DNS 是否被 44.0.0.0/8 接管（TUN 正常时应为 198.18.x 或真实公网 IP）
function Get-SystemDnsProbe {
    if (((Get-Date) - $script:DnsCache.t).TotalSeconds -lt 10) { return $script:DnsCache.v }
    $ip = ''
    try {
        $a = @(Resolve-DnsName 'api.anthropic.com' -Type A -NoHostsFile -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -First 1)
        if ($a) { $ip = [string]$a.IPAddress }
    } catch {}
    $script:DnsCache.v = $ip; $script:DnsCache.t = Get-Date
    return $ip
}

function Get-NicSnapshot($cfg) {    $r = [ordered]@{ tunUp = $false; tunAddr = ''; v6 = @() }
    foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        $props = $ni.GetIPProperties()
        if ($ni.Name -eq $cfg.tunAlias) {
            $r.tunUp = ($ni.OperationalStatus -eq 'Up')
            foreach ($a in $props.UnicastAddresses) { if ($a.Address.AddressFamily -eq 'InterNetwork') { $r.tunAddr = $a.Address.ToString() } }
            continue
        }
        if ($ni.NetworkInterfaceType -eq 'Loopback') { continue }
        foreach ($a in $props.UnicastAddresses) {
            if ($a.Address.AddressFamily -eq 'InterNetworkV6') {
                $t = $a.Address.ToString()
                if ($t -match '^[23]') { $r.v6 += ('{0}@{1}' -f $t, $ni.Name) }
            }
        }
    }
    return $r
}

# 让系统“选源地址”：UDP connect 不发包，但能得到路由所选的本地源地址；源地址==TUN 地址 即默认出口经由 TUN
function Get-RouteSourceAddress {
    $u = $null
    try { $u = New-Object System.Net.Sockets.UdpClient; $u.Connect('1.1.1.1', 53); return $u.Client.LocalEndPoint.Address.ToString() }
    catch { return '' }
    finally { if ($u) { $u.Close() } }
}

function Get-PathHash([string]$s) {
    return [BitConverter]::ToString((New-Object Security.Cryptography.SHA1Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes($s.ToLowerInvariant()))).Replace('-','').Substring(0,10)
}
# 内核放行规则按程序路径命名（与 BuiltinCore.ps1 的 Get-BCRuleName 一致）：增删内核时“先加新、后删旧”，不会出现放行空档
function Get-CoreRuleName([string]$p) { return ('ClaudeGuard-Allow-Core-' + (Get-PathHash $p)) }

$script:StaticRuleNames = @('ClaudeGuard-Allow-TUN','ClaudeGuard-Allow-LAN','ClaudeGuard-Allow-DHCP','ClaudeGuard-Block-IPv6')

function Get-ExpectedBaselineNames($cfg) {
    # 自动跟随入口模式：
    # - 内核只放行 TCP 出站（任意端口），UDP/明文 DNS 一律默认拒绝
    # - 中继入口的 IP/端口变了，订阅更新后内核直接连新入口，无需改防火墙
    $names = @($script:StaticRuleNames)
    foreach ($p in (Get-CorePathsCached $cfg)) { $names += (Get-CoreRuleName $p) }
    return $names
}

# name -> 规则定义字符串（注册表，毫秒级）
function Get-GuardRuleRawFast {
    $map = @{}
    try {
        $k = Get-Item -LiteralPath $script:FwRulesKey -ErrorAction Stop
        foreach ($n in $k.GetValueNames()) { if ($n -like 'ClaudeGuard-*') { $map[$n] = [string]$k.GetValue($n) } }
    } catch {}
    return $map
}

function ConvertTo-La4([string]$cidr) {
    # 198.18.0.0/24 -> 198.18.0.0/255.255.255.0（注册表里的写法）
    if ($cidr -notmatch '^(\d+\.\d+\.\d+\.\d+)/(\d+)$') { return $cidr }
    $ip = $Matches[1]; $bits = [int]$Matches[2]
    if ($bits -ge 32) { return $ip }
    $oct = @()
    for ($i = 0; $i -lt 4; $i++) { $b = [Math]::Max(0, [Math]::Min(8, $bits - 8 * $i)); $oct += (256 - [Math]::Pow(2, 8 - $b)) }
    return ('{0}/{1}' -f $ip, ($oct -join '.'))
}

function Set-FirewallBaseline($cfg, [bool]$KeepTunOff = $false) {
    # 增量同步（不再“先全删再重建”）：缺的补上、该改的原地改、多余的最后删。规则变化期间没有放行空档。
    # KeepTunOff：整机断网期间同步，不把已关闭的 TUN 放行重新打开
    Write-Log '同步防火墙基线规则…'
    $script:CoreCache.t = [DateTime]::MinValue
    $raw = Get-GuardRuleRawFast
    $cidrs = @(@($cfg.tunLocalCidr) | Where-Object { $_ })

    if (-not $raw.ContainsKey('ClaudeGuard-Allow-TUN')) {
        Invoke-Mut '允许：源地址为 TUN 的流量' {
            New-GuardRule @{ Name='ClaudeGuard-Allow-TUN'; DisplayName='ClaudeGuard 放行 TUN 流量'; Direction='Outbound'; Action='Allow'; LocalAddress=$cidrs; Enabled=$(if ($KeepTunOff) { 'False' } else { 'True' }) }
        } | Out-Null
    } else {
        $have = @([regex]::Matches($raw['ClaudeGuard-Allow-TUN'], '\|LA4=([^|]+)') | ForEach-Object { $_.Groups[1].Value }) | Sort-Object
        $want = @($cidrs | ForEach-Object { ConvertTo-La4 $_ }) | Sort-Object
        if (($have -join ',') -ne ($want -join ',')) {
            Invoke-Mut ("TUN 放行地址 → {0}" -f ($cidrs -join ', ')) { Set-NetFirewallRule -Name 'ClaudeGuard-Allow-TUN' -LocalAddress $cidrs } | Out-Null
        }
        if (-not $KeepTunOff -and $raw['ClaudeGuard-Allow-TUN'] -notmatch '\|Active=TRUE(\||$)') { Invoke-Mut '启用 TUN 放行规则' { Set-NetFirewallRule -Name 'ClaudeGuard-Allow-TUN' -Enabled True } | Out-Null }
    }
    if (-not $raw.ContainsKey('ClaudeGuard-Allow-LAN')) {
        Invoke-Mut '允许：局域网' {
            New-GuardRule @{ Name='ClaudeGuard-Allow-LAN'; DisplayName='ClaudeGuard 放行局域网'; Direction='Outbound'; Action='Allow';
                RemoteAddress=@('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16','169.254.0.0/16','224.0.0.0/4','255.255.255.255') }
        } | Out-Null
    }
    if (-not $raw.ContainsKey('ClaudeGuard-Allow-DHCP')) {
        Invoke-Mut '允许：DHCP' {
            New-GuardRule @{ Name='ClaudeGuard-Allow-DHCP'; DisplayName='ClaudeGuard 放行 DHCP'; Direction='Outbound'; Action='Allow'; Protocol='UDP'; LocalPort=68; RemotePort=67 }
        } | Out-Null
    }
    # 内核只放行 TCP：规则里没有任何公网 DIRECT（只有局域网与白羊订阅域名），内核的公网连接
    # 只会是“中继入口 / 订阅更新 / 解析中继域名的 DoH”。入口端口变化后订阅一更新就自动恢复。
    # UDP（含明文 DNS 53）不放行，避免运营商看到/篡改明文 DNS。
    $keep = @($script:StaticRuleNames)
    foreach ($p in (Get-CorePaths $cfg)) {
        $n = Get-CoreRuleName $p
        $keep += $n
        if (-not $raw.ContainsKey($n)) {
            Invoke-Mut ("允许：内核 {0} 的 TCP 出站（中继入口 + DoH）" -f $p) {
                New-GuardRule @{ Name=$n; DisplayName=("ClaudeGuard 内核 TCP {0}" -f (Split-Path $p -Leaf)); Direction='Outbound'; Action='Allow'; Program=$p; Protocol='TCP' }
            } | Out-Null
        } elseif ($raw[$n] -notmatch '\|Active=TRUE(\||$)') {
            Invoke-Mut ("启用内核放行 {0}" -f $p) { Set-NetFirewallRule -Name $n -Enabled True } | Out-Null
        }
    }
    foreach ($n in @('ClaudeGuard-Allow-LAN','ClaudeGuard-Allow-DHCP','ClaudeGuard-Block-IPv6')) {
        if ($raw.ContainsKey($n) -and $raw[$n] -notmatch '\|Active=TRUE(\||$)') { Invoke-Mut ("启用 {0}" -f $n) { Set-NetFirewallRule -Name $n -Enabled True } | Out-Null }
    }
    if (-not $raw.ContainsKey('ClaudeGuard-Block-IPv6')) {
        Invoke-Mut '封锁：全部全球单播 IPv6' {
            New-GuardRule @{ Name='ClaudeGuard-Block-IPv6'; DisplayName='ClaudeGuard 封锁 IPv6'; Direction='Outbound'; Action='Block'; RemoteAddress='2000::/3' }
        } | Out-Null
    }
    # 最后才删多余的放行（旧编号规则 / 切换前的内核）
    foreach ($n in @($raw.Keys)) {
        if ($n -like 'ClaudeGuard-Block-Claude-*' -or $keep -contains $n) { continue }
        Invoke-Mut ("移除不再需要的规则 {0}" -f $n) { Remove-NetFirewallRule -Name $n } | Out-Null
    }
}

function Set-DefaultOutbound([string]$Action) {
    Invoke-Mut ("防火墙出站默认动作 → {0}" -f $Action) {
        Set-NetFirewallProfile -Profile Domain,Private,Public -DefaultOutboundAction $Action
    } | Out-Null
}

function Sync-ClaudeBlockRules($cfg, [bool]$EnableNow) {
    $paths = Get-ClaudePrograms $cfg
    $state = Get-GuardRuleStateFast
    $existing = @($state.Keys | Where-Object { $_ -like 'ClaudeGuard-Block-Claude-*' })
    $wanted = @{}
    foreach ($p in $paths) {
        $h = [BitConverter]::ToString((New-Object Security.Cryptography.SHA1Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes($p.ToLowerInvariant()))).Replace('-','').Substring(0,10)
        $wanted['ClaudeGuard-Block-Claude-' + $h] = $p
    }
    $flag = if ($EnableNow) { 'True' } else { 'False' }
    foreach ($n in $wanted.Keys) {
        $p = $wanted[$n]
        if ($existing -notcontains $n) {
            Invoke-Mut ("创建 Claude 程序封锁规则 {0}" -f $p) {
                New-GuardRule @{ Name=$n; DisplayName=("ClaudeGuard 封锁 {0}" -f $p); Direction='Outbound'; Action='Block'; Program=$p; Enabled=$flag }
            } | Out-Null
        } elseif ([bool]$state[$n] -ne $EnableNow) {
            Invoke-Mut ("{0} Claude 程序封锁 {1}" -f $(if($EnableNow){'启用'}else{'停用'}), $n) { Set-NetFirewallRule -Name $n -Enabled $flag } | Out-Null
        }
    }
    foreach ($n in $existing) {
        if (-not $wanted.ContainsKey($n)) { Invoke-Mut ("移除过期封锁规则 {0}" -f $n) { Remove-NetFirewallRule -Name $n } | Out-Null }
    }
}

function Set-TunAllow([bool]$On) {
    $flag = if ($On) { 'True' } else { 'False' }
    Invoke-Mut ("TUN 放行规则 → {0}" -f $flag) { Set-NetFirewallRule -Name 'ClaudeGuard-Allow-TUN' -Enabled $flag } | Out-Null
}

# ----------------------------------------------------------------------
# hosts 黑洞（带标记块，不触碰用户其它条目）
# ----------------------------------------------------------------------
function Test-HostsBlock {
    try {
        $t = [System.IO.File]::ReadAllText($script:HostsPath)
        return $t.Contains($script:HostsBegin)
    } catch { return $false }
}

function Set-HostsBlock([bool]$On, $cfg) {
    if ((Test-HostsBlock) -eq $On) { return }
    Invoke-Mut ("hosts 黑洞 → {0}" -f $(if($On){'开启'}else{'关闭'})) {
        $text = [System.IO.File]::ReadAllText($script:HostsPath)
        $lines = New-Object System.Collections.Generic.List[string]
        $skip = $false
        foreach ($l in ($text -split "`r?`n")) {
            if ($l.StartsWith($script:HostsBegin)) { $skip = $true; continue }
            if ($l.StartsWith($script:HostsEnd))   { $skip = $false; continue }
            if (-not $skip) { $lines.Add($l) }
        }
        while ($lines.Count -gt 0 -and $lines[$lines.Count-1].Trim() -eq '') { $lines.RemoveAt($lines.Count-1) }
        if ($On) {
            $lines.Add(''); $lines.Add($script:HostsBegin)
            foreach ($d in $cfg.blackholeDomains) { $lines.Add("0.0.0.0 $d") }
            $lines.Add($script:HostsEnd)
        }
        $enc = New-Object System.Text.UTF8Encoding($false)
        for ($try = 1; $try -le 4; $try++) {
            try { [System.IO.File]::WriteAllText($script:HostsPath, (($lines -join "`r`n") + "`r`n"), $enc); break }
            catch { if ($try -eq 4) { throw }; Start-Sleep -Milliseconds 400 }
        }
        Clear-DnsClientCache
    } | Out-Null
}

# ----------------------------------------------------------------------
# IPv6：解绑物理网卡（记录以便应急恢复）
# ----------------------------------------------------------------------
function Read-RescueState {
    if (Test-Path -LiteralPath $script:RescueFile) {
        try { return (Get-Content -LiteralPath $script:RescueFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
    }
    return $null
}
function Save-RescueState($obj) {
    if ($DryRun) { return }
    ($obj | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $script:RescueFile -Encoding UTF8
}

function Sync-Ipv6Unbind($cfg) {
    if (-not $cfg.ipv6Unbind) { return }
    $rs = Read-RescueState
    $done = @(); if ($rs -and $rs.ipv6Disabled) { $done = @($rs.ipv6Disabled) }
    $changed = $false
    foreach ($b in (Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue)) {
        if ($b.Name -eq $cfg.tunAlias) { continue }
        if ($b.Enabled) {
            Invoke-Mut ("解绑 IPv6：{0}" -f $b.Name) { Disable-NetAdapterBinding -Name $b.Name -ComponentID ms_tcpip6 } | Out-Null
            if ($done -notcontains $b.Name) { $done += $b.Name }
            $changed = $true
        }
    }
    if ($changed -and $rs -ne $null) { $rs.ipv6Disabled = $done; Save-RescueState $rs }
    elseif ($changed) { Save-RescueState ([ordered]@{ ipv6Disabled = $done }) }
}

# ----------------------------------------------------------------------
# 探针
# ----------------------------------------------------------------------
# 探针脚本块：同时用于同步调用（加固验证）和后台 runspace（看门狗主循环，避免阻塞 2 秒节拍）
$script:ProbeBlock = {
    param($urls, $timeoutSec, $wantAsn, $proxyUrl)
    $ErrorActionPreference = 'Continue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    function Get-Text([string]$Url, [int]$Sec) {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        # 强制走 Clash 的 mixed-port：测的是 Clash 节点本身，而不是整机出口。
        # 这样即使还有第二条隧道/UU/白羊在跑，也不会把它的出口当成 Clash 的出口。
        if ($proxyUrl) { $req.Proxy = New-Object System.Net.WebProxy($proxyUrl) } else { $req.Proxy = $null }
        $req.Timeout = $Sec * 1000
        $req.ReadWriteTimeout = $Sec * 1000
        $req.UserAgent = 'Mozilla/5.0 ClaudeGuard'
        $req.KeepAlive = $false
        $resp = $null
        try {
            $resp = $req.GetResponse()
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            try { return $sr.ReadToEnd() } finally { $sr.Close() }
        } finally { if ($resp) { $resp.Close() } }
    }
    $r = [ordered]@{ ok=$false; ip=''; country=''; asn=0; isp=''; source=''; error=''; ms=0 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lastErr = ''
    foreach ($u in $urls) {
        try {
            $txt = Get-Text $u $timeoutSec
            if ($txt -match '(?m)^loc=([A-Za-z]{2})\s*$') {
                $r.country = $Matches[1].ToUpperInvariant()
                if ($txt -match '(?m)^ip=(\S+)') { $r.ip = $Matches[1] }
                $r.source = ([Uri]$u).Host; $r.ok = $true
            } elseif ($txt.TrimStart().StartsWith('{')) {
                $j = $txt | ConvertFrom-Json
                if ($j.country_code) {
                    $r.country = ([string]$j.country_code).ToUpperInvariant(); $r.ip = [string]$j.ip
                    if ($j.connection) { $r.asn = [int64]$j.connection.asn; $r.isp = [string]$j.connection.isp }
                    $r.source = ([Uri]$u).Host; $r.ok = $true
                }
            }
            if ($r.ok) { break }
            $lastErr = '响应无法解析'
        } catch { $lastErr = $_.Exception.Message }
    }
    if ($r.ok) { $r.error = '' } else { $r.error = $lastErr }
    # 主探针成功但还没有 ASN：补查 ipwho.is（失败不影响判定）
    if ($r.ok -and $wantAsn -and -not $r.asn) {
        try {
            $j = (Get-Text 'https://ipwho.is/' $timeoutSec) | ConvertFrom-Json
            if ($j.connection) { $r.asn = [int64]$j.connection.asn; $r.isp = [string]$j.connection.isp }
        } catch {}
    }
    $r.ms = [int]$sw.ElapsedMilliseconds
    return [pscustomobject]$r
}

function Get-EgressIdentity($cfg, [bool]$WantAsn = $true) {
    return (& $script:ProbeBlock $cfg.probeUrls $cfg.probeTimeoutSec $WantAsn $cfg.probeProxy)
}

function Start-ProbeAsync($ctx, $cfg, [bool]$WantAsn) {
    if ($ctx.probePs) { return }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:ProbeBlock.ToString()).AddArgument($cfg.probeUrls).AddArgument($cfg.probeTimeoutSec).AddArgument($WantAsn).AddArgument($cfg.probeProxy)
    $ctx.probeAsync = $ps.BeginInvoke()
    $ctx.probePs = $ps
    $ctx.probeStarted = Get-Date
}

# 返回 $null 表示仍在运行；否则返回探针结果对象（超时则返回失败结果）
function Receive-ProbeAsync($ctx, $cfg) {
    if (-not $ctx.probePs) { return $null }
    $limit = ($cfg.probeUrls.Count + 1) * $cfg.probeTimeoutSec + 8
    $elapsed = ((Get-Date) - $ctx.probeStarted).TotalSeconds
    if (-not $ctx.probeAsync.IsCompleted) {
        if ($elapsed -le $limit) { return $null }
        try { $ctx.probePs.Stop() } catch {}
        try { $ctx.probePs.Dispose() } catch {}
        $ctx.probePs = $null; $ctx.probeAsync = $null
        return [pscustomobject]@{ ok=$false; ip=''; country=''; asn=0; isp=''; source=''; error='探针线程超时'; ms=[int]($elapsed*1000) }
    }
    $res = $null
    try { $res = @($ctx.probePs.EndInvoke($ctx.probeAsync)) | Select-Object -First 1 } catch { $res = $null }
    try { $ctx.probePs.Dispose() } catch {}
    $ctx.probePs = $null; $ctx.probeAsync = $null
    if (-not $res) { return [pscustomobject]@{ ok=$false; ip=''; country=''; asn=0; isp=''; source=''; error='探针无返回'; ms=0 } }
    return $res
}

# ----------------------------------------------------------------------
# 体检
# ----------------------------------------------------------------------
function New-Check([string]$Id, [string]$Title, [bool]$Ok, [string]$Level, [string]$Detail) {
    return [pscustomobject]@{ id=$Id; title=$Title; ok=$Ok; level=$Level; detail=$Detail }
}

# 国内开发镜像直连白名单（必须与 sRYohxTjB2to.js 一致）：整条规则精确匹配，宽后缀/其他域名都会判为违规 DIRECT
$script:DevMirrorDirectRegex = '^\s*-\s*(DOMAIN-SUFFIX,(m\.daocloud\.io|1ms\.run|cloud\.tencent\.com|qcloud\.com|qcloudimg\.com|myqcloud\.com|tencentcloudapi\.com|tencent-cloud\.com|tencent-cloud\.net|tencent-cloud\.cn)|DOMAIN,(ccr\.ccs\.tencentyun\.com|mirror\.ccs\.tencentyun\.com|registry\.npmmirror\.com|cdn\.npmmirror\.com|maven\.aliyun\.com|mirrors\.aliyun\.com)),DIRECT\s*$'

function Test-RuntimeConfig($cfg) {
    $res = @()
    $path = $cfg.runtimeYaml
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        return @(New-Check 'cfg' '运行配置核对' $false 'warn' $(if ($cfg.engine -eq 'builtin') { '未找到内置引擎的运行配置，无法核对' } else { '未找到 clash-verge.yaml，无法核对' }))
    }
    $lines = Get-Content -LiteralPath $path -Encoding UTF8
    $text  = $lines -join "`n"
    $section = ''; $proxyCount = 0; $badDirect = @()
    foreach ($l in $lines) {
        if ($l -match '^([A-Za-z0-9_-]+):') { $section = $Matches[1] }
        if ($section -eq 'proxies' -and ($l -match '^\s*-\s+name:' -or $l -match '^\s*-\s*\{')) { $proxyCount++ }
        if ($section -eq 'rules' -and $l -match 'DIRECT' ) {
            if ($l -notmatch '(IP-CIDR,(127\.|10\.|172\.16\.|192\.168\.|169\.254\.|224\.|255\.255\.255\.255)|DOMAIN-SUFFIX,(baiyang888\.xyz|czzpp\.cn|j396\.com|smirsb\.cn),DIRECT|^\s*-\s*DOMAIN,byang\.oss-ap-southeast-1\.aliyuncs\.com,DIRECT\s*$)' -and
                $l -notmatch $script:DevMirrorDirectRegex) { $badDirect += $l.Trim() }
        }
    }
    $pinOk = ($proxyCount -eq 1) -and $text.Contains('MATCH,KR-ONLY') -and ($text -notmatch 'type:\s*url-test') -and ($text -notmatch 'GEOIP,') -and ($badDirect.Count -eq 0)
    $detail = "节点数={0}；非局域网 DIRECT 规则={1}" -f $proxyCount, $badDirect.Count
    $res += New-Check 'pin' '节点钉死（仅锁定的单个节点 · 无 DIRECT 回落）' $pinOk 'hard' $detail
    $modeOk = ($text -match '(?m)^mode:\s*rule') -and ($text -match '(?m)^ipv6:\s*false')
    $res += New-Check 'mode' '模式 rule · 全局 IPv6 关闭' $modeOk 'hard' $(if($modeOk){'mode=rule, ipv6=false'}else{'mode 或 ipv6 与期望不符'})
    $quic = $text.Contains('AND,((NETWORK,UDP),(DST-PORT,443)),REJECT')
    if ($cfg.netMode -eq 'sysproxy') {
        # 系统代理模式不建 TUN：没有 strict-route/MTU 可查；不走代理的程序由防火墙默认拒绝直接拦住
        $res += New-Check 'strict' '系统代理模式（不使用 TUN）' $true 'hard' '只有走系统代理的程序能联网，其余程序被防火墙拦截（断开，不回落直连）'
    } else {
        $strict = ($text -match '(?m)^\s+strict-route:\s*true')
        $res += New-Check 'strict' 'TUN strict-route' $strict 'hard' $(if($strict){'已开启'}else{'未开启：存在 DNS 多宿主泄露风险'})
        $mtu = ($text -match '(?m)^\s+mtu:\s*1360')
        $res += New-Check 'mtu' 'TUN MTU 1360' $mtu 'warn' $(if($mtu){'已生效'}else{'未生效（可能出现 bad record MAC）'})
    }
    $res += New-Check 'quic' 'QUIC(UDP 443) 已屏蔽' $quic 'warn' $(if($quic){'浏览器改走 TCP，经单 TCP 隧道更稳'}else{'未屏蔽：QUIC 塞进 TCP 隧道，丢包时明显卡顿'})
    return $res
}

function Test-RuntimeConfigCached($cfg) {
    $path = $cfg.runtimeYaml
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return (Test-RuntimeConfig $cfg) }
    $mt = (Get-Item -LiteralPath $path).LastWriteTimeUtc
    if ($mt -ne $script:RtCache.mtime) { $script:RtCache.res = @(Test-RuntimeConfig $cfg); $script:RtCache.mtime = $mt }
    return $script:RtCache.res
}

function Invoke-HealthChecks($cfg, [bool]$CutAll = $false) {
    $checks = @()

    # 内核进程（名称跟随引擎：Clash Verge = verge-mihomo；内置引擎 = cg-mihomo）
    $core = @()
    foreach ($cn in @($cfg.coreNames)) { $core += @([System.Diagnostics.Process]::GetProcessesByName(([string]$cn -replace '\.exe$', ''))) }
    $coreTitle = $(if ($cfg.engine -eq 'builtin') { '内置内核进程（cg-mihomo）' } else { 'Mihomo 内核进程' })
    $checks += New-Check 'core' $coreTitle ($core.Count -gt 0) 'hard' $(if($core.Count -gt 0){"PID " + (($core | ForEach-Object { $_.Id }) -join ',')}else{'未运行'})

    # TUN 网卡 / 地址 / IPv6
    $nic = Get-NicSnapshot $cfg
    $sysProxy = ($cfg.engine -eq 'builtin' -and $cfg.netMode -eq 'sysproxy')
    $tunPrefix = (([string]$cfg.tunLocalCidr -split '/')[0] -replace '\.\d+$', '.')
    if ($sysProxy) {
        $checks += New-Check 'tun' '系统代理模式' $true 'hard' '不使用 TUN 网卡'
        $checks += New-Check 'tunaddr' 'TUN 地址与放行规则匹配' $true 'hard' '系统代理模式：不适用'
    } else {
        $checks += New-Check 'tun' ("TUN 网卡 {0}" -f $cfg.tunAlias) $nic.tunUp 'hard' $(if($nic.tunUp){'Up'}else{'不存在或未连接'})
        $tunAddrOk = $nic.tunAddr.StartsWith($tunPrefix)
        $checks += New-Check 'tunaddr' 'TUN 地址与放行规则匹配' ($tunAddrOk -or -not $nic.tunUp) 'hard' $(if($nic.tunAddr){"TUN 地址 $($nic.tunAddr)"}else{'-'})
    }

    # 默认出口的源地址 == TUN 地址（即路由经由 TUN；同时就是防火墙放行规则所依据的条件）
    $src = Get-RouteSourceAddress
    $routeOk = [bool]($nic.tunUp -and $src -and ($src -eq $nic.tunAddr))
    if ($sysProxy) {
        # 没有 TUN：普通程序走物理网卡会被防火墙默认拒绝拦住；能联网的只有走系统代理（本机内核）的程序
        $checks += New-Check 'route' '不走代理的程序无法直连' $true 'hard' ('系统代理模式：出口源地址 {0}，出站由防火墙默认拒绝' -f $(if($src){$src}else{'-'}))
    } elseif ($CutAll) {
        # 整机断网时 TUN 放行规则已关闭，connect 会被防火墙拦截，此项无法测量；按“已按预期断网”处理，否则永远无法恢复
        $checks += New-Check 'route' '默认出口路由经过 TUN' $true 'hard' '已按预期断网（TUN 放行规则关闭），恢复探测期间不做路由检查'
    } else {
        $checks += New-Check 'route' '默认出口路由经过 TUN' $routeOk 'hard' $(if($src){"出口源地址 $src"}else{'无可用路由'})
    }

    # 防火墙服务 / 默认动作 / 基线规则
    $svc = $null; try { $svc = Get-Service -Name mpssvc -ErrorAction Stop } catch {}
    $svcOk = [bool]($svc -and $svc.Status -eq 'Running')
    $checks += New-Check 'fwsvc' 'Windows 防火墙服务' $svcOk 'hard' $(if($svc){$svc.Status.ToString()}else{'未知'})
    $pol = Get-OutboundPolicy
    $allBlock = ($pol.Count -eq 3) -and (@($pol | Where-Object { $_ -ne 'Block' }).Count -eq 0)
    $checks += New-Check 'fwdef' '出站默认拒绝（三个配置文件）' $allBlock 'hard' $(if($allBlock){'Domain/Private/Public = Block'}else{'未全部设为 Block'})
    $want = Get-ExpectedBaselineNames $cfg
    $map = Get-GuardRuleStateFast
    $missing = @($want | Where-Object { -not $map.ContainsKey($_) -or (-not $map[$_] -and -not ($_ -eq 'ClaudeGuard-Allow-TUN' -and $CutAll)) })
    if ($missing.Count -gt 0) {
        # 注册表快速读取发现异常：用权威 cmdlet 复核一次，避免误判
        try {
            $have = @(Get-NetFirewallRule -Group $script:RuleGroup -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq 'True' -or ($_.Name -eq 'ClaudeGuard-Allow-TUN' -and $CutAll) } | ForEach-Object { $_.Name })
            $missing = @($want | Where-Object { $have -notcontains $_ })
        } catch {}
    }
    $checks += New-Check 'fwrules' '防火墙基线规则完整' ($missing.Count -eq 0) 'hard' $(if($missing.Count -eq 0){"$($want.Count) 条齐全"}else{"缺少/未启用：" + ($missing -join ', ')})

    # IPv6
    $checks += New-Check 'ipv6' '物理网卡无公网 IPv6 地址' ($nic.v6.Count -eq 0) 'warn' $(if($nic.v6.Count -eq 0){'无'}else{($nic.v6 -join '; ')})

    # 与白羊 App 共用目录冲突
    $by = @([System.Diagnostics.Process]::GetProcessesByName('baiyang'))
    $byDetail = $(if ($cfg.engine -eq 'builtin') { '白羊 App 的加速层可能另建隧道接管网络，建议退出' } else { '白羊 App 与 Clash Verge 共用同一配置目录，并行运行会互相覆盖配置' })
    $checks += New-Check 'baiyang' '白羊 App 未并行运行' ($by.Count -eq 0) 'warn' $(if($by.Count -eq 0){'未运行'}else{$byDetail})

    # 内置引擎：电脑上其他 Clash 是否也在跑（它们的内核不在防火墙放行名单里，连不出去；另一张 TUN 会和本机抢路由）
    if ($cfg.engine -eq 'builtin') {
        $others = @()
        foreach ($n in @('clash-verge', 'verge-mihomo', 'verge-mihomo-alpha', 'clash-meta', 'mihomo', 'clash')) {
            $c = @([System.Diagnostics.Process]::GetProcessesByName($n)).Count
            if ($c -gt 0) { $others += "$n.exe" }
        }
        try {
            foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
                if ($ni.Name -ne $cfg.tunAlias -and $ni.OperationalStatus -eq 'Up' -and ($ni.Name -match '^(Mihomo|Meta|Clash)' -or $ni.Description -match 'Mihomo|Meta Tunnel')) { $others += ('TUN 网卡 ' + $ni.Name) }
            }
        } catch {}
        $checks += New-Check 'conflict' '没有其他 Clash 同时运行' ($others.Count -eq 0) 'warn' $(if($others.Count -eq 0){'未发现'}else{($others -join '、') + '：已被防火墙隔离（连不出去），但可能和本机抢路由，建议退出'})
    }

    # 第二条隧道：44.0.0.0/8 / 114.114.114.114/32 / 198.16.x.x 会在 Clash TUN 之前接管 DNS 与流量
    $rogue = @(Get-RogueTunnelInfo)
    $checks += New-Check 'rogue' '无第二条隧道（44.0.0.0/8 / 198.16.0.2）' ($rogue.Count -eq 0) 'hard' $(if($rogue.Count -eq 0){'未发现'}else{($rogue -join '; ')})

    # 系统 DNS 不能被 44.0.0.0/8 接管；整机断网期间跳过
    if ($CutAll) {
        $dnsOk = $true; $dnsDetail = '整机断网期间跳过'
    } else {
        $sysDns = Get-SystemDnsProbe
        $dnsOk = [bool]($sysDns -and ($sysDns -notlike '44.0.0.*'))
        $dnsDetail = if ($sysDns) { "api.anthropic.com -> $sysDns" } else { '解析失败' }
    }
    $checks += New-Check 'dns' '系统 DNS 未被 44.0.0.0/8 接管' $dnsOk 'hard' $dnsDetail

    $checks += (Test-RuntimeConfigCached $cfg)
    return $checks
}

# ----------------------------------------------------------------------
# 状态 / 指令
# ----------------------------------------------------------------------
function Write-State($state) {
    try {
        if (-not (Test-Path -LiteralPath $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null }
        $tmp = $script:StateFile + '.tmp'
        ($state | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $script:StateFile -Force
    } catch { Write-Log "写入状态失败：$($_.Exception.Message)" 'WARN' }
}

function Read-Commands {
    # 读取并删除全部待处理指令：cmd.json（旧写法）+ cmd.<id>.json（新写法，多条指令不会互相覆盖）；.tmp 是正在写入的，跳过
    $out = @()
    try {
        if (-not [IO.Directory]::Exists($script:CmdDir)) { return $out }
        $files = @([IO.Directory]::GetFiles($script:CmdDir, 'cmd*.json') | Sort-Object { [IO.File]::GetLastWriteTimeUtc($_) })
        foreach ($f in $files) {
            $c = $null
            try { $c = [string](([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8)) | ConvertFrom-Json).cmd } catch {}
            try { [IO.File]::Delete($f) } catch {}
            if ($c) { $out += $c }
        }
    } catch {}
    return $out
}

# ----------------------------------------------------------------------
# 看门狗主循环
# ----------------------------------------------------------------------
function New-GuardContext {
    return [ordered]@{
        mode='INIT'; reason='守护刚启动，等待首次完整体检'; forced=$false; cutAll=$false
        okStreak=0; failStreak=0; lastProbe=[DateTime]::MinValue; lastFw=[DateTime]::MinValue
        lastClaudeSync=[DateTime]::MinValue; lastAsn=[DateTime]::MinValue
        identity=$null; lastIp=''; since=(Get-Date); lockCount=0
        lockKind=''; hardOkTicks=0; probeError=''; lastProbeOk=[DateTime]::MinValue
        probePs=$null; probeAsync=$null; probeStarted=[DateTime]::MinValue; windowOpen=$false
        probeNow=$false; probeReq=[DateTime]::MinValue; probeDone=[DateTime]::MinValue; probeLastOk=$false; probeManual=$false; probeDoneManual=$false
        lastCoreStart=(Get-Date); cfgStamp=(Get-CfgStamp); switching=$null
    }
}

# 热切换标记（state\switching.json，只有管理员能写）：返回 $null 或 { target; since; until }
function Get-SwitchMarker {
    if (-not (Test-Path -LiteralPath $script:SwitchFile)) { return $null }
    try {
        $j = Get-Content -LiteralPath $script:SwitchFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $until = [DateTime]::Parse([string]$j.until, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
        if ($until -gt (Get-Date) -and $until -lt (Get-Date).AddMinutes(5)) { return $j }
    } catch {}
    return $null
}

# 配置文件变化时原地重新加载（切换引擎 / 节点不必重启守护，避免重启带来的拦截空档）
function Update-ConfigIfChanged($ctx, $cfg) {
    $stamp = Get-CfgStamp
    if ($stamp -eq $ctx.cfgStamp) { return }
    $new = Get-Config -Strict
    if (-not $new) { return }        # 文件正被改写：下个节拍再读
    $ctx.cfgStamp = $stamp
    $changed = @()
    foreach ($k in @($new.Keys)) {
        $a = ConvertTo-Json @($cfg[$k]) -Compress -Depth 4; $b = ConvertTo-Json @($new[$k]) -Compress -Depth 4
        if ($a -ne $b) { $changed += $k }
        $cfg[$k] = $new[$k]
    }
    if ($changed.Count -eq 0) { return }
    Write-Log ("守护配置已更新（{0}），已在运行中生效" -f ($changed -join ', '))
    $script:CoreCache.t = [DateTime]::MinValue; $script:RtCache.mtime = [DateTime]::MinValue
    $ctx.lastCoreStart = Get-Date
    if (@($changed | Where-Object { $_ -in @('engine','netMode','coreRoots','coreNames','coreDiscovery','tunLocalCidr','extraAllowPrograms','tunAlias') }).Count -gt 0) {
        $pol = Get-OutboundPolicy $true
        if ($pol.Count -eq 3 -and @($pol | Where-Object { $_ -ne 'Block' }).Count -eq 0) {
            Set-FirewallBaseline $cfg
            if ($ctx.cutAll) { Set-TunAllow $false }
        }
    }
    if ($changed -contains 'expectedCountry') { $ctx.lastProbe = [DateTime]::MinValue; $ctx.okStreak = 0 }
    if ($changed -contains 'engine' -or $changed -contains 'netMode') { $ctx.lastProbe = (Get-Date).AddSeconds(-[double]$cfg.probeIntervalSec + 6) }
}

function Enter-Lock($ctx, $cfg, [string]$Reason, [bool]$CutAll, [string]$Kind) {
    $newlyLocked = ($ctx.mode -ne 'LOCKED')
    # 种类只升不降：hard < country/forced（整机断网的必须由探针确认 KR 才能解除）
    if ($newlyLocked -or $Kind -ne 'hard') { $ctx.lockKind = $Kind }
    $ctx.hardOkTicks = 0
    $ctx.mode = 'LOCKED'; $ctx.reason = $Reason
    if ($newlyLocked) { $ctx.lockCount++; $ctx.since = Get-Date; Write-Log "【封锁】进入封锁：$Reason" 'WARN' }
    Set-HostsBlock $true $cfg
    Sync-ClaudeBlockRules $cfg $true
    if ($CutAll -and -not $ctx.cutAll) { Set-TunAllow $false; $ctx.cutAll = $true; Write-Log '已关闭 TUN 放行规则：整机断网' 'WARN' }
    $ctx.okStreak = 0
}

function Exit-Lock($ctx, $cfg) {
    Set-HostsBlock $false $cfg
    Sync-ClaudeBlockRules $cfg $false
    if ($ctx.cutAll) { Set-TunAllow $true; $ctx.cutAll = $false; $ctx.windowOpen = $false }
    $wasKind = $ctx.lockKind
    $ctx.mode = 'OK'; $ctx.reason = '一切正常'; $ctx.since = Get-Date; $ctx.lockKind = ''; $ctx.hardOkTicks = 0; $ctx.okStreak = 0
    if ($wasKind -eq 'hard' -or $wasKind -eq 'init') { $ctx.lastProbe = [DateTime]::MinValue }   # 解除后尽快复核一次出口
    Write-Log '【放行】解除封锁：TUN、路由与防火墙基线正常' 'INFO'
}

function Invoke-GuardTick($ctx, $cfg) {
    $now = Get-Date

    # --- 配置热加载 / 热切换标记 ---
    try { Update-ConfigIfChanged $ctx $cfg } catch { Write-Log ("重新加载配置失败：{0}" -f $_.Exception.Message) 'WARN' }
    $sw = Get-SwitchMarker
    if ($sw -and -not $ctx.switching) { Write-Log ("开始热切换：{0}" -f $sw.target) }
    if (-not $sw -and $ctx.switching) {
        Write-Log '热切换结束'
        $ctx.lastFw = [DateTime]::MinValue
        # 切换中临时多放行的内核 / TUN 网段（无论切换成功还是失败）按当前配置收回；增量同步，不产生放行空档
        try {
            if ($ctx.mode -ne 'INIT' -and @(Get-OutboundPolicy $true | Where-Object { $_ -ne 'Block' }).Count -eq 0) {
                Set-FirewallBaseline $cfg
                if ($ctx.cutAll) { Set-TunAllow $false }
            }
        } catch { Write-Log ("切换后同步防火墙失败：{0}" -f $_.Exception.Message) 'WARN' }
    }
    $ctx.switching = $sw
    $switching = [bool]$sw

    # --- 指令（只接受“更严”的指令）---
    foreach ($cmd in @(Read-Commands)) {
    if ($cmd -eq 'force-lock')   { $ctx.forced = $true;  Write-Log '收到指令：强制断网' 'WARN' }
    if ($cmd -eq 'force-unlock') { $ctx.forced = $false; Write-Log '收到指令：取消强制断网（是否放行仍由健康检查决定）' }
    if ($cmd -eq 'probe-now')    { $ctx.probeNow = $true; $ctx.probeReq = $now }   # 正在探测时也不会丢：本次结束后立刻再测一次
    if ($cmd -eq 'reload-core' -and $cfg.engine -eq 'builtin') {
        # 订阅更新后：按锁定节点重新生成运行配置（校验通过才替换）并热重载内核。只会生成“锁定节点 + 固定规则”
        if ($script:BCLoaded) {
            try { $r = Update-BCRuntime; Write-Log ("收到指令：更新内置引擎配置 → {0}" -f $r.message) $(if ($r.ok -and -not $r.missing) { 'INFO' } else { 'WARN' }) }
            catch { Write-Log ("更新内置引擎配置失败：{0}" -f $_.Exception.Message) 'WARN' }
            $ctx.lastProbe = [DateTime]::MinValue
        } else { Write-Log '收到指令 reload-core，但内置引擎模块未加载' 'WARN' }
    }
    }

    # --- 内置引擎：内核意外退出时自动拉起（每 20 秒最多一次；期间防火墙默认拒绝，不会漏）---
    if ($cfg.engine -eq 'builtin' -and $script:BCLoaded -and -not $switching) {
        # lastCoreStart 初始为守护启动时间：开机时内核计划任务和守护同时启动，先给内核 20 秒
        if (@(Get-BCCoreProcess).Count -eq 0 -and ($now - $ctx.lastCoreStart).TotalSeconds -ge 20) {
            $ctx.lastCoreStart = $now
            Write-Log '内置内核未运行，正在重新启动' 'WARN'
            try { [void](Start-BCCore) } catch { Write-Log ("启动内置内核失败：{0}" -f $_.Exception.Message) 'ERROR' }
        }
    }

    # --- 防火墙自愈（每 10 秒；先用毫秒级读取发现异常，再调用慢 cmdlet 修复）---
    if (($now - $ctx.lastFw).TotalSeconds -ge 10) {
        $ctx.lastFw = $now
        try {
            if ($ctx.mode -ne 'INIT' -and -not $switching) {
                $want = Get-ExpectedBaselineNames $cfg
                $map = Get-GuardRuleStateFast
                $miss = @($want | Where-Object { -not $map.ContainsKey($_) })
                if ($miss.Count -gt 0) {
                    $have = @(Get-NetFirewallRule -Group $script:RuleGroup -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
                    $miss = @($want | Where-Object { $have -notcontains $_ })
                }
                if ($miss.Count -gt 0) {
                    Write-Log ("检测到基线规则缺失：{0}，尝试重建" -f ($miss -join ',')) 'WARN'
                    Set-FirewallBaseline $cfg
                    Set-DefaultOutbound 'Block'
                    if ($ctx.cutAll) { Set-TunAllow $false }
                }
            }
            # 出站默认拒绝：任何时候（含热切换期间）都强制保持
            if ($ctx.mode -ne 'INIT') {
                $pol = Get-OutboundPolicy $true
                if (@($pol | Where-Object { $_ -ne 'Block' }).Count -gt 0 -or $pol.Count -ne 3) {
                    Write-Log '检测到出站默认动作被改动，重新设为 Block' 'WARN'
                    Set-DefaultOutbound 'Block'
                    [void](Get-OutboundPolicy $true)
                }
            }
            Sync-Ipv6Unbind $cfg
        } catch { Write-Log "防火墙自愈异常：$($_.Exception.Message)" 'WARN' }
    }

    # --- Claude 程序封锁规则同步（每 60 秒）---
    if (($now - $ctx.lastClaudeSync).TotalSeconds -ge 60) {
        $ctx.lastClaudeSync = $now
        try { Sync-ClaudeBlockRules $cfg ($ctx.mode -eq 'LOCKED') } catch {}
    }

    # --- 体检 ---
    $checks = Invoke-HealthChecks $cfg ([bool]$ctx.cutAll)
    $hardFail = @($checks | Where-Object { -not $_.ok -and $_.level -eq 'hard' })

    # --- 出口探针（后台异步；主循环保持 2 秒节拍）---
    $probed = $false
    if ($ctx.forced -and $ctx.windowOpen) { Set-TunAllow $false; $ctx.windowOpen = $false }
    if ($ctx.probePs) {
        $id = Receive-ProbeAsync $ctx $cfg
        if ($id -and $switching) {
            # 切换途中的探针结果不可信（新旧内核交替），丢弃；切换结束后很快重新探测
            if ($ctx.windowOpen) { Set-TunAllow $false; $ctx.windowOpen = $false }
            $ctx.lastProbe = (Get-Date).AddSeconds(-[double]$cfg.probeIntervalSec + 8)
            if ($ctx.probeManual) { $ctx.probeNow = $true }   # 手动检查被切换打断：切换结束后马上补测
            $id = $null
        }
        if ($id) {
            $probed = $true
            $ctx.lastProbe = Get-Date
            $ctx.probeDone = Get-Date; $ctx.probeLastOk = [bool]$id.ok; $ctx.probeDoneManual = [bool]$ctx.probeManual; $ctx.probeManual = $false
            if ($ctx.windowOpen) { Set-TunAllow $false; $ctx.windowOpen = $false }
            if (-not $id.ok) {
                # 只记录，不封锁；保留上一次确认过的出口身份
                $ctx.failStreak++
                $ctx.probeError = [string]$id.error
                if ($ctx.failStreak -eq 1 -or ($ctx.failStreak % 10) -eq 0) { Write-Log ("出口探针失败（第 {0} 次，不影响放行）：{1}" -f $ctx.failStreak, $id.error) 'INFO' }
            } else {
                $ctx.failStreak = 0; $ctx.probeError = ''; $ctx.lastProbeOk = Get-Date
                $prev = $ctx.identity
                $ctx.identity = [ordered]@{ ok=$true; ip=$id.ip; country=$id.country; asn=$id.asn; isp=$id.isp; source=$id.source; ms=$id.ms; time=(Get-Date).ToString('o'); error='' }
                if ($prev -and $prev.ok -and $prev.asn -and -not $id.asn -and $prev.ip -eq $id.ip) { $ctx.identity.asn = $prev.asn; $ctx.identity.isp = $prev.isp }
                if ($id.ip -and $ctx.lastIp -ne $id.ip) { Write-Log ("出口 IP：{0} ({1}) ASN {2} 来源 {3}" -f $id.ip, $id.country, $id.asn, $id.source); $ctx.lastIp = $id.ip }
            }
        }
    } else {
        $probeEvery = if ($ctx.cutAll -or $ctx.failStreak -gt 0 -or -not $ctx.identity) { $cfg.probeRetrySec } else { $cfg.probeIntervalSec }
        # 关键：即使存在硬故障也要继续探测，否则永远拿不到 identity，永远无法恢复。
        # 出口探针通过 Clash 的 mixed-port 发起，不再受“第二条隧道”影响。
        if (-not $ctx.forced -and -not $switching -and ($ctx.probeNow -or (($now - $ctx.lastProbe).TotalSeconds -ge $probeEvery))) {
            $ctx.probeManual = [bool]$ctx.probeNow; $ctx.probeNow = $false
            if ($ctx.cutAll) { Set-TunAllow $true; $ctx.windowOpen = $true; Start-Sleep -Milliseconds 300 }
            # ASN 只在：从未查到 / 每 asnRefreshSec 一次 时补查，避免 ipwho.is 限流
            $needAsn = ($ctx.lastAsn -eq [DateTime]::MinValue) -or (($now - $ctx.lastAsn).TotalSeconds -ge $cfg.asnRefreshSec) -or ($ctx.identity -and $ctx.identity.ok -and -not $ctx.identity.asn -and (($now - $ctx.lastAsn).TotalSeconds -ge 1800))
            if ($needAsn) { $ctx.lastAsn = $now }
            Start-ProbeAsync $ctx $cfg $needAsn
        }
    }

    # --- 判定 ---
    # 只有两类原因会封锁：本地结构性硬故障；探针“成功”并确认出口国家错误（或用户强制）。
    # 探针失败/超时一律不封锁。
    $countryBad = [bool]($probed -and $ctx.identity -and $ctx.identity.ok -and $ctx.failStreak -eq 0 -and $ctx.identity.country -ne $cfg.expectedCountry)
    $asnBad = [bool]($probed -and $ctx.identity -and $ctx.identity.ok -and $ctx.failStreak -eq 0 -and $cfg.strictAsn -and $ctx.identity.asn -and (@($cfg.allowedAsns) -notcontains [int64]$ctx.identity.asn))
    if ($ctx.forced) {
        Enter-Lock $ctx $cfg '用户强制断网' $true 'forced'
    } elseif ($switching) {
        # 热切换中：新旧内核交替，内核/TUN/路由短暂缺失属正常；防火墙默认拒绝不变，只有两个严格内核能出网，不会泄露。
        # 保持当前状态，不新增拦截也不解除拦截；切换标记最长 5 分钟自动失效
        if ($ctx.mode -ne 'OK') { $ctx.hardOkTicks = 0 }
    } elseif ($countryBad) {
        Enter-Lock $ctx $cfg ("出口国家为 {0}，期望 {1}（IP {2}）" -f $ctx.identity.country, $cfg.expectedCountry, $ctx.identity.ip) $true 'country'
    } elseif ($asnBad) {
        Enter-Lock $ctx $cfg ("出口 ASN {0} 不在白名单" -f $ctx.identity.asn) $true 'country'
    } elseif ($hardFail.Count -gt 0) {
        if ($ctx.mode -eq 'INIT') { $ctx.reason = '启动体检未通过：' + (($hardFail | ForEach-Object { $_.title }) -join '、'); $ctx.hardOkTicks = 0 }
        else { Enter-Lock $ctx $cfg ('硬故障：' + (($hardFail | ForEach-Object { $_.title }) -join '、')) $false 'hard' }
    } elseif ($ctx.mode -ne 'OK') {
        $kind = if ($ctx.mode -eq 'INIT') { 'init' } else { $ctx.lockKind }
        if ($kind -eq 'country' -or $kind -eq 'forced') {
            # 整机断网后：必须探针确认出口 = 期望国家
            if ($probed -and $ctx.identity -and $ctx.identity.ok -and $ctx.failStreak -eq 0 -and $ctx.identity.country -eq $cfg.expectedCountry) { $ctx.okStreak++ }
            if ($ctx.okStreak -ge $cfg.recoverThreshold) { Exit-Lock $ctx $cfg }
            else { $ctx.reason = ("出口复核中：已确认 {0}/{1} 次" -f $ctx.okStreak, $cfg.recoverThreshold) }
        } else {
            # 硬故障 / 启动：本地体检连续正常即放行（防泄露由防火墙 + TUN 结构保证）
            $ctx.hardOkTicks++
            if ($ctx.hardOkTicks -ge $cfg.hardRecoverTicks) { $ctx.lockKind = $kind; Exit-Lock $ctx $cfg }
            else { $ctx.reason = ("本地体检恢复中：{0}/{1}" -f $ctx.hardOkTicks, $cfg.hardRecoverTicks) }
        }
    }

    # --- 写状态 ---
    $state = [ordered]@{
        version=$script:Version; pid=$PID; ts=$now.ToString('o'); dryRun=[bool]$DryRun
        mode=$ctx.mode; reason=$ctx.reason; forced=$ctx.forced; cutAll=$ctx.cutAll; since=([DateTime]$ctx.since).ToString('o')
        failStreak=$ctx.failStreak; okStreak=$ctx.okStreak; lockCount=$ctx.lockCount
        identity=$ctx.identity; checks=$checks
        probe=[ordered]@{ failStreak=$ctx.failStreak; error=$ctx.probeError; lastOk=$(if($ctx.lastProbeOk -ne [DateTime]::MinValue){([DateTime]$ctx.lastProbeOk).ToString('o')}else{''}); intervalSec=$cfg.probeIntervalSec
            # 手动“立即检查出口”的回执：控制台据此显示真实结果（成功/失败原因），而不是只显示“已请求”
            running=[bool]$ctx.probePs; pending=[bool]$ctx.probeNow
            req=$(if($ctx.probeReq -ne [DateTime]::MinValue){([DateTime]$ctx.probeReq).ToString('o')}else{''})
            done=$(if($ctx.probeDone -ne [DateTime]::MinValue){([DateTime]$ctx.probeDone).ToString('o')}else{''}); doneOk=[bool]$ctx.probeLastOk; doneManual=[bool]$ctx.probeDoneManual }
        hostsBlocked=(Test-HostsBlock)
        expected=[ordered]@{ country=$cfg.expectedCountry; asns=$cfg.allowedAsns }
        engine=[string]$cfg.engine; netMode=[string]$cfg.netMode; cfgStamp=[int64]$ctx.cfgStamp
        switching=$(if ($sw) { [ordered]@{ target=[string]$sw.target; since=[string]$sw.since } } else { $null })
    }
    Write-State $state
    return $state
}

# ----------------------------------------------------------------------
# 模式实现
# ----------------------------------------------------------------------
function Invoke-Harden($cfg) {
    if (-not $DryRun -and -not (Test-Admin)) { throw '需要管理员权限' }
    Ensure-Dirs
    Write-Log '===== 开始加固（默认拒绝出站 · 仅放行 TUN 与内核）====='

    # 先确认没有第二条隧道。否则 44.0.0.0/8 等流量会被当成“非 TUN”直接封死，或者被误放行，
    # 两种结果都不安全。这里必须让用户先清理，不能带着两条隧道加固。
    $rogue = @(Get-RogueTunnelInfo)
    if ($rogue.Count -gt 0) {
        throw ("检测到第二条隧道，拒绝加固：{0}。请先运行「修复-Claude安全网络.bat」清理（或退出白羊/UU 并禁用 wintun）。" -f ($rogue -join '; '))
    }

    if ($cfg.engine -eq 'builtin' -and $cfg.netMode -eq 'sysproxy') {
        $running = 0; foreach ($cn in @($cfg.coreNames)) { $running += @([System.Diagnostics.Process]::GetProcessesByName(([string]$cn -replace '\.exe$', ''))).Count }
        if ($running -eq 0) { throw '内置内核未运行，拒绝加固（否则会把自己断网）。' }
    } else {
        $tun = Get-NetAdapter -Name $cfg.tunAlias -ErrorAction SilentlyContinue
        $who = $(if ($cfg.engine -eq 'builtin') { '内置引擎' } else { 'Clash Verge' })
        if (-not $tun -or $tun.Status -ne 'Up') { throw "TUN 网卡 $($cfg.tunAlias) 未运行，拒绝加固（否则会把自己断网）。请先启动 $who 并开启 TUN。" }
    }
    $cores = @(Get-CorePaths $cfg | Where-Object { $_ -like '*mihomo*' })
    if ($cores.Count -eq 0) { throw '未发现 Mihomo 内核路径，拒绝加固。' }
    Write-Log ("放行的内核：" + ($cores -join ' | '))

    # 记录原始默认动作，供 Rescue 恢复
    $orig = @{}
    foreach ($p in (Get-NetFirewallProfile -ErrorAction SilentlyContinue)) { $orig[$p.Name] = $p.DefaultOutboundAction.ToString() }
    $rs = Read-RescueState
    if (-not $rs -or -not $rs.originalOutbound) { Save-RescueState ([ordered]@{ originalOutbound = $orig; ipv6Disabled = @() }) }

    Set-FirewallBaseline $cfg
    Sync-ClaudeBlockRules $cfg $false
    Sync-Ipv6Unbind $cfg
    Set-DefaultOutbound 'Block'
    Clear-DnsClientCache

    if ($DryRun) { Write-Log '[DRY] 跳过加固后的连通性验证'; return }
    Write-Log '加固已应用，验证经由 TUN 的出口连通性…'
    $ok = $false
    for ($i = 1; $i -le 6; $i++) {
        $id = Get-EgressIdentity $cfg
        if ($id.ok -and $id.country -eq $cfg.expectedCountry) { $ok = $true; Write-Log ("验证通过：出口 {0} ({1})" -f $id.ip, $id.country); break }
        Write-Log ("验证第 {0} 次未通过：{1}" -f $i, $id.error) 'WARN'
        Start-Sleep -Seconds 3
    }
    if (-not $ok) {
        Write-Log '加固后经由 TUN 无法访问外网，自动回滚！' 'ERROR'
        Invoke-Rescue $cfg -KeepTask
        throw '加固后验证失败，已自动回滚到加固前的网络状态。'
    }
    Write-Log '===== 加固完成 ====='
}

function Invoke-Rescue($cfg, [switch]$KeepTask) {
    if (-not $DryRun -and -not (Test-Admin)) { throw '需要管理员权限' }
    Write-Log '===== 应急恢复：恢复默认网络 =====' 'WARN'
    if (-not $KeepTask) {
        Invoke-Mut '停用计划任务' { Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue; Disable-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue | Out-Null } | Out-Null
        Get-Process -Name powershell -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID } | ForEach-Object {
            try {
                $cl = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine
                if ($cl -and $cl -match 'ClaudeGuard\.ps1' -and $cl -match '-Mode\s+Run') { Invoke-Mut ("结束守护进程 PID {0}" -f $_.Id) { Stop-Process -Id $_.Id -Force } | Out-Null }
            } catch {}
        }
        # Rust 版守护（7.0 起）
        Get-Process -Name 'cg-guard' -ErrorAction SilentlyContinue | ForEach-Object {
            $gp = $_
            Invoke-Mut ("结束守护进程 cg-guard PID {0}" -f $gp.Id) { Stop-Process -Id $gp.Id -Force } | Out-Null
        }
    }
    $rs = Read-RescueState
    foreach ($name in @('Domain','Private','Public')) {
        $act = 'NotConfigured'
        if ($rs -and $rs.originalOutbound -and $rs.originalOutbound.$name) { $act = [string]$rs.originalOutbound.$name }
        if ($act -eq 'Block') { $act = 'NotConfigured' }
        Invoke-Mut ("{0} 出站默认动作 → {1}" -f $name, $act) { Set-NetFirewallProfile -Profile $name -DefaultOutboundAction $act } | Out-Null
    }
    Invoke-Mut '移除全部 ClaudeGuard 防火墙规则' { Get-NetFirewallRule -Group $script:RuleGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule } | Out-Null
    # 内置引擎：关闭保护 = 停掉自带内核（TUN 随之消失），回到普通网络；不管当前是哪个引擎都执行，保证应急恢复彻底
    Invoke-Mut '停止内置内核' {
        if (Get-ScheduledTask -TaskName 'ClaudeGuardCore' -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName 'ClaudeGuardCore' -ErrorAction SilentlyContinue
            Disable-ScheduledTask -TaskName 'ClaudeGuardCore' -ErrorAction SilentlyContinue | Out-Null
        }
        Get-Process -Name 'cg-mihomo' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    } | Out-Null
    Set-HostsBlock $false $cfg
    if ($rs -and $rs.ipv6Disabled) {
        foreach ($n in @($rs.ipv6Disabled)) {
            Invoke-Mut ("恢复 IPv6 绑定：{0}" -f $n) { Enable-NetAdapterBinding -Name $n -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue } | Out-Null
        }
    }
    Invoke-Mut '清空 DNS 缓存' { Clear-DnsClientCache } | Out-Null
    Invoke-Mut '删除应急状态快照' { Remove-Item -LiteralPath $script:RescueFile -Force -ErrorAction SilentlyContinue } | Out-Null
    Invoke-Mut '清除热切换标记' { Remove-Item -LiteralPath $script:SwitchFile, $script:ProgressFile -Force -ErrorAction SilentlyContinue } | Out-Null
    # 告诉控制台“保护已关闭”（否则旧状态文件会被误判为守护失联）
    if (-not $KeepTask) {
        try { Write-State ([ordered]@{ version=$script:Version; pid=$PID; ts=(Get-Date).ToString('o'); dryRun=[bool]$DryRun; mode='OFF'; reason='保护已关闭'; checks=@() }) } catch {}
    }
    Write-Log '===== 应急恢复完成：网络已回到默认状态 =====' 'WARN'
}

# 守护程序：同目录有 cg-guard.exe（7.0 起的 Rust 版）就用它，否则用本脚本的 Run 模式
function Get-GuardExe { $p = Join-Path $PSScriptRoot 'cg-guard.exe'; if ([IO.File]::Exists($p)) { return $p } return '' }

function Register-GuardTask {
    $exe = Get-GuardExe
    if ($exe) { $action = New-ScheduledTaskAction -Execute $exe -Argument 'run' -WorkingDirectory $PSScriptRoot }
    else {
        $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode Run -Quiet' -f $PSCommandPath
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    }
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount
    $settings  = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    return $(if ($exe) { 'cg-guard.exe' } else { 'ClaudeGuard.ps1' })
}

function Invoke-Install($cfg) {
    if (-not $DryRun -and -not (Test-Admin)) { throw '需要管理员权限' }
    Invoke-Mut '注册计划任务 ClaudeGuard（SYSTEM · 开机自启 · 失败自动重启）' {
        $which = Register-GuardTask
        Write-Log ("守护程序：{0}" -f $which)
        Enable-ScheduledTask -TaskName $script:TaskName | Out-Null
        Start-ScheduledTask -TaskName $script:TaskName
    } | Out-Null
}

# 更新程序用：按当前文件重新注册计划任务，保持原来的启用/停用状态，不启动
function Invoke-RegisterTask {
    if (-not $DryRun -and -not (Test-Admin)) { throw '需要管理员权限' }
    $old = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if (-not $old) { Write-Log '计划任务 ClaudeGuard 不存在（保护未安装），跳过'; return }
    $wasEnabled = ($old.State -ne 'Disabled')
    Invoke-Mut '重新注册计划任务 ClaudeGuard' {
        $which = Register-GuardTask
        if (-not $wasEnabled) { Disable-ScheduledTask -TaskName $script:TaskName | Out-Null }
        Write-Log ("计划任务已指向 {0}（{1}）" -f $which, $(if ($wasEnabled) { '启用' } else { '保持停用' }))
    } | Out-Null
}

function Invoke-Uninstall($cfg) {
    Invoke-Rescue $cfg
    Invoke-Mut '删除计划任务' { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue } | Out-Null
}

function Invoke-Audit {
    $app = @{}; Get-NetFirewallApplicationFilter -All | ForEach-Object { $app[$_.InstanceID] = $_.Program }
    $adr = @{}; Get-NetFirewallAddressFilter -All | ForEach-Object { $adr[$_.InstanceID] = $_ }
    $svc = @{}; Get-NetFirewallServiceFilter -All | ForEach-Object { $svc[$_.InstanceID] = $_.Service }
    $out = @()
    foreach ($r in (Get-NetFirewallRule -Direction Outbound -Action Allow -Enabled True -PolicyStore ActiveStore)) {
        if ($r.Group -eq $script:RuleGroup) { continue }
        $a = $adr[$r.Name]; if (-not $a) { continue }
        $remoteAny = (@($a.RemoteAddress) -contains 'Any')
        if ($remoteAny) { $out += [pscustomobject]@{ Name=$r.DisplayName; Program=$app[$r.Name]; Service=$svc[$r.Name] } }
    }
    return $out
}

# ----------------------------------------------------------------------
# 入口
# ----------------------------------------------------------------------
Ensure-Dirs
$cfg = Get-Config

# 内置引擎模块（订阅/运行配置/内核进程）：总是加载，运行中切换到内置引擎时直接可用；加载失败不影响守护本身
$script:BCLoaded = $false
try {
    . (Join-Path $PSScriptRoot 'BaiyangProfile.ps1')
    . (Join-Path $PSScriptRoot 'BuiltinCore.ps1')
    $script:BCLoaded = $true
} catch { if ($cfg.engine -eq 'builtin') { Write-Log ("内置引擎模块加载失败：{0}" -f $_.Exception.Message) 'WARN' } }

if (-not $DryRun -and $Mode -in @('Run','Harden','Rescue','Resume','Install','Uninstall','SyncBaseline','SyncClaude','SyncIpv6','SetTunAllow','StartCore','ReloadCore','RegisterTask') -and -not (Test-Admin)) {
    Write-Host '需要管理员权限，请以管理员身份运行。' -ForegroundColor Red
    exit 3
}

switch ($Mode) {
    'Harden'    { Invoke-Harden $cfg }
    'Rescue'    { Invoke-Rescue $cfg }
    'Resume'    { Invoke-Harden $cfg; Invoke-Install $cfg }
    'Install'   { Invoke-Install $cfg }
    'Uninstall' { Invoke-Uninstall $cfg }
    'Audit'     { Invoke-Audit | Format-Table -AutoSize -Wrap }
    'RegisterTask' { Invoke-RegisterTask }
    # ---- 以下模式由 cg-guard.exe 委托调用（失败时以非 0 退出码返回，cg-guard 记录日志）----
    'SyncBaseline' {
        # 只在保护开启（出站默认拒绝）时同步，避免保护关闭后被重新加回规则
        $pol = Get-OutboundPolicy $true
        if ($pol.Count -eq 3 -and @($pol | Where-Object { $_ -ne 'Block' }).Count -eq 0) {
            Set-FirewallBaseline $cfg ([bool]$CutAll)
            if ($CutAll) { Set-TunAllow $false }
        } else { Write-Log '保护未开启（出站默认未拒绝），跳过同步防火墙基线' }
    }
    'SyncClaude'   { Sync-ClaudeBlockRules $cfg ([bool]$Enable -and -not $NoEnable) }
    'SyncIpv6'     { Sync-Ipv6Unbind $cfg }
    'SetTunAllow'  { Set-TunAllow ([bool]$Enable -and -not $NoEnable) }
    'StartCore'    {
        if (-not $script:BCLoaded) { throw '内置引擎模块未加载' }
        if ($DryRun) { Write-Log '[DRY] 启动内置内核' 'DRY'; return }
        [void](Start-BCCore)
    }
    'ReloadCore'   {
        if (-not $script:BCLoaded) { throw '内置引擎模块未加载' }
        if ($DryRun) { Write-Log '[DRY] 更新内置引擎配置' 'DRY'; return }
        $r = Update-BCRuntime
        Write-Log ("更新内置引擎配置 → {0}" -f $r.message) $(if ($r.ok -and -not $r.missing) { 'INFO' } else { 'WARN' })
        if (-not $r.ok) { exit 1 }
    }
    'Status'    {
        if (Test-Path -LiteralPath $script:StateFile) { Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 } else { Write-Host '尚无状态文件' }
    }
    'Once' {
        $ctx = New-GuardContext
        $ctx.lastProbe = [DateTime]::MinValue
        $s = Invoke-GuardTick $ctx $cfg
        $s.checks | Format-Table title, ok, level, detail -AutoSize -Wrap
        Write-Host ("状态：{0}  原因：{1}" -f $s.mode, $s.reason)
        if ($s.identity) { Write-Host ("出口：{0}  国家={1}  ASN={2}  ISP={3}  耗时={4}ms" -f $s.identity.ip, $s.identity.country, $s.identity.asn, $s.identity.isp, $s.identity.ms) }
    }
    'Run' {
        $created = $false
        $mutex = New-Object System.Threading.Mutex($true, 'Global\ClaudeGuard.Run', [ref]$created)
        if (-not $created) { Write-Log '已有守护实例在运行，退出。'; exit 0 }
        Write-Log ("ClaudeGuard {0} 启动 (PID {1}){2}" -f $script:Version, $PID, $(if($DryRun){' [DryRun]'}else{''}))
        $ctx = New-GuardContext
        $prev = $null
        try { if (Test-Path -LiteralPath $script:StateFile) { $prev = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json } } catch {}
        $pol = @(); try { $pol = Get-OutboundPolicy $true } catch {}
        $locked = ($pol.Count -eq 3 -and @($pol | Where-Object { $_ -ne 'Block' }).Count -eq 0)
        # 保护开着时先把防火墙规则同步到当前版本（旧版的编号规则会被替换，先加后删，不断网）
        if ($locked) { try { Set-FirewallBaseline $cfg } catch { Write-Log ("同步防火墙规则失败：{0}" -f $_.Exception.Message) 'WARN' } }
        # 热启动：守护只是被重启（更新程序 / 计划任务自动重启），上一个实例 90 秒内还在正常放行，
        # 且现在本地体检全部通过 → 直接沿用放行状态，不再拦截 Claude 6~10 秒
        $warm = $false
        try {
            if ($locked -and $prev -and [string]$prev.mode -eq 'OK' -and -not $prev.forced) {
                $age = ((Get-Date).ToUniversalTime() - [DateTime]::Parse([string]$prev.ts, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()).TotalSeconds
                if ($age -ge 0 -and $age -le 90) {
                    $hard = @(Invoke-HealthChecks $cfg $false | Where-Object { -not $_.ok -and $_.level -eq 'hard' })
                    if ($hard.Count -eq 0) { $warm = $true } else { Write-Log ('热启动未通过本地体检：' + (($hard | ForEach-Object { $_.title }) -join '、')) }
                }
            }
        } catch {}
        if ($warm) {
            $ctx.mode = 'OK'; $ctx.reason = '一切正常'
            if ($prev.identity -and $prev.identity.ok) {
                $ctx.identity = [ordered]@{ ok=$true; ip=[string]$prev.identity.ip; country=[string]$prev.identity.country; asn=$prev.identity.asn; isp=[string]$prev.identity.isp; source=[string]$prev.identity.source; ms=$prev.identity.ms; time=[string]$prev.identity.time; error='' }
                $ctx.lastIp = [string]$prev.identity.ip; $ctx.lastAsn = Get-Date
            }
            try { if ($prev.since) { $ctx.since = [DateTime]::Parse([string]$prev.since) } } catch {}
            $ctx.lastProbe = (Get-Date).AddSeconds(-[double]$cfg.probeIntervalSec + 10)   # 10 秒后复核一次出口
            Set-HostsBlock $false $cfg
            Sync-ClaudeBlockRules $cfg $false
            Write-Log '守护热启动：本地体检通过，沿用放行状态（Claude 不中断）'
        } else {
            # 启动即进入“封锁待验证”状态：未证明安全之前不放行 Claude
            Set-HostsBlock $true $cfg
            Sync-ClaudeBlockRules $cfg $true
        }
        while ($true) {
            try { [void](Invoke-GuardTick $ctx $cfg) }
            catch { Write-Log ("主循环异常：{0}" -f $_.Exception.Message) 'ERROR' }
            Start-Sleep -Seconds 2
        }
    }
}
