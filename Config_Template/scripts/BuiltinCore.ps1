<#
  BuiltinCore.ps1 —— Claude保护 内置引擎（自带 mihomo 内核，v8 起）
  先 dot-source BaiyangProfile.ps1，再 dot-source 本文件。

  与电脑上其他 Clash（Clash Verge / 白羊 App）完全分开，避免冲突：
    · 独立内核文件   C:\ProgramData\ClaudeGuard\core\cg-mihomo.exe（防火墙只放行这一个路径）
    · 独立目录       core\home（运行配置，仅管理员可写）/ core\sub（订阅，普通用户可写）/ core\logs
    · 独立端口       混合代理 17897 · 控制接口 127.0.0.1:19097（带随机密钥）· DNS 127.0.0.1:11053
    · 独立 TUN 网卡  「ClaudeGuard」，地址 198.19.0.1（Clash Verge 是「Mihomo」198.18.0.1）
    · 独立计划任务   ClaudeGuardCore（SYSTEM），只在保护开启时运行
  运行配置由本模块直接生成：只放锁定的那一个节点 + 固定规则，没有全局模式、没有 DIRECT 兜底。
#>

$script:BC_Root       = Join-Path $script:BP_GuardRoot 'core'
$script:BC_Exe        = Join-Path $script:BC_Root 'cg-mihomo.exe'
$script:BC_ProcName   = 'cg-mihomo'
$script:BC_Home       = Join-Path $script:BC_Root 'home'
$script:BC_Config     = Join-Path $script:BC_Home 'config.yaml'
$script:BC_SubDir     = Join-Path $script:BC_Root 'sub'
$script:BC_LogDir     = Join-Path $script:BC_Root 'logs'
$script:BC_LogFile    = Join-Path $script:BC_LogDir 'core.log'
$script:BC_EngineFile = Join-Path $script:BP_GuardRoot 'engine.json'
$script:BC_TaskName   = 'ClaudeGuardCore'
$script:BC_TunName    = 'ClaudeGuard'
$script:BC_FakeIpRange = '198.19.0.1/16'
$script:BC_TunAddr    = '198.19.0.1/30'
$script:BC_TunCidr    = '198.19.0.0/24'
$script:BC_Group      = 'KR-ONLY'          # 策略组名固定（守护按此名称校验），实际节点由锁定记录决定
$script:BC_VergeDefaultDir = 'D:\Program Files\uu\Clash Verge'
$script:BC_VergeServiceCores = 'C:\ProgramData\clash-verge-service\cores'   # Clash Verge 服务模式会把内核复制到这里运行
$script:BC_VergeCidr  = '198.18.0.0/24'
$script:BC_SwitchFile = Join-Path $script:BP_GuardRoot 'state\switching.json'
$script:BC_ProgressFile = Join-Path $script:BP_GuardRoot 'state\switch-progress.json'
$script:BC_FwRulesKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules'

# ------------------------------------------------------------------ 引擎设置（engine.json，管理员可写，所有人可读）
function Get-BCSettings {
    $h = [ordered]@{ engine = 'verge'; netMode = 'tun'; subSource = 'baiyang'; mixedPort = 17897; apiPort = 19097; dnsPort = 11053; secret = '' }
    try {
        if (Test-Path -LiteralPath $script:BC_EngineFile) {
            $o = Get-Content -LiteralPath $script:BC_EngineFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
        }
    } catch {}
    return [pscustomobject]$h
}

function Save-BCSettings($S) {
    if (-not $S.secret) { $S.secret = -join ((1..24) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) }) }
    $o = [ordered]@{}
    foreach ($p in $S.PSObject.Properties) { $o[$p.Name] = $p.Value }
    [IO.File]::WriteAllText($script:BC_EngineFile, ($o | ConvertTo-Json), $script:BP_Utf8)
}

function Get-BCEngine { return [string](Get-BCSettings).engine }

# ------------------------------------------------------------------ 目录与内核文件
function Initialize-BCDirs {
    # 需要管理员权限。sub 目录允许普通用户写（控制台以普通用户身份更新订阅/导入配置）；
    # 运行配置 home 只允许管理员/SYSTEM 写：订阅内容再怎么变，生成的配置都只含锁定节点 + 固定规则。
    foreach ($d in @($script:BC_Root, $script:BC_Home, $script:BC_SubDir, $script:BC_LogDir)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    try { & icacls.exe $script:BC_SubDir /grant '*S-1-5-32-545:(OI)(CI)M' 2>&1 | Out-Null } catch {}
}

function Get-BCVergeCoreSource {
    # 内置内核来自本机 Clash Verge 自带的 verge-mihomo.exe
    $roots = @()
    try {
        $c = Get-Content -LiteralPath (Join-Path $script:BP_GuardRoot 'guard.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $roots += @($c.vergeCoreRoots) + @($c.coreRoots)
    } catch {}
    $roots += @($script:BC_VergeDefaultDir, "$env:ProgramFiles\Clash Verge")
    foreach ($r in ($roots | Where-Object { $_ } | Select-Object -Unique)) {
        $x = Join-Path $r 'verge-mihomo.exe'
        if (Test-Path -LiteralPath $x) { return $x }
    }
    return $null
}

function Get-BCFileHash([string]$Path) {
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } catch { return '' }
}

function Install-BCCoreExe {
    # 复制内核；返回说明。内核正在运行时不覆盖（下次关闭保护后再更新）
    $r = Invoke-BPGuardJson @('core-install')
    if ($r) { if ($r.ok) { return [string]$r.message }; throw [string]$r.message }
    Initialize-BCDirs
    $src = Get-BCVergeCoreSource
    if (-not $src) {
        if (Test-Path -LiteralPath $script:BC_Exe) { return '未找到 Clash Verge 内核，继续使用已安装的内置内核' }
        throw '未找到 Clash Verge 自带的 verge-mihomo.exe，无法安装内置内核'
    }
    if (Test-Path -LiteralPath $script:BC_Exe) {
        if ((Get-BCFileHash $src) -eq (Get-BCFileHash $script:BC_Exe)) { return '内置内核已是最新' }
        if (Get-BCCoreProcess) { return '内置内核正在运行，下次关闭保护后再更新' }
    }
    Copy-Item -LiteralPath $src -Destination $script:BC_Exe -Force
    return ('已安装内置内核（来自 {0}）' -f $src)
}

function Get-BCCoreVersion {
    if (-not (Test-Path -LiteralPath $script:BC_Exe)) { return '' }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo($script:BC_Exe, '-v')
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi); $o = $p.StandardOutput.ReadToEnd(); [void]$p.WaitForExit(3000)
        if ($o -match '(v\d+\.\d+\.\d+)') { return $Matches[1] }
    } catch {}
    return ''
}

# ------------------------------------------------------------------ 订阅（core\sub）
function Get-BCSubFile([string]$Source) { if ($Source -eq 'local') { return (Join-Path $script:BC_SubDir 'local.yaml') } return (Join-Path $script:BC_SubDir 'baiyang.yaml') }
function Get-BCSubMetaFile([string]$Source) { if ($Source -eq 'local') { return (Join-Path $script:BC_SubDir 'local.meta.json') } return (Join-Path $script:BC_SubDir 'baiyang.meta.json') }

function Get-BCSubMeta([string]$Source = 'baiyang') {
    $f = Get-BCSubMetaFile $Source
    try { if (Test-Path -LiteralPath $f) { return (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json) } } catch {}
    return $null
}

function Save-BCSubMeta([string]$Source, $Meta) {
    $o = [ordered]@{}
    if ($Meta -is [System.Collections.IDictionary]) { foreach ($k in $Meta.Keys) { $o[$k] = $Meta[$k] } }
    else { foreach ($p in $Meta.PSObject.Properties) { $o[$p.Name] = $p.Value } }
    [IO.File]::WriteAllText((Get-BCSubMetaFile $Source), ($o | ConvertTo-Json), $script:BP_Utf8)
}

function ConvertFrom-BCUserInfo([string]$Header) {
    # subscription-userinfo: upload=1; download=2; total=3; expire=4
    $o = [ordered]@{}
    foreach ($part in ($Header -split ';')) {
        if ($part -match '^\s*(upload|download|total|expire)\s*=\s*(\d+)') { $o[$Matches[1]] = [double]$Matches[2] }
    }
    return $o
}

function Get-BCSubText([string]$Source = '') {
    if (-not $Source) { $Source = [string](Get-BCSettings).subSource }
    return (Read-BPText (Get-BCSubFile $Source))
}

function Get-BCNodes([string]$Source = '') { return @(Get-BPNodeList (Get-BCSubText $Source)) }

function Initialize-BCSub {
    # 首次使用：从 Clash Verge 里的白羊订阅复制一份（地址 + 内容），之后由本程序自己更新
    Initialize-BCDirs
    $meta = Get-BCSubMeta 'baiyang'
    $file = Get-BCSubFile 'baiyang'
    if ($meta -and $meta.url -and (Test-Path -LiteralPath $file)) { return $true }
    try {
        $d = Get-BPDataDir
        $p = Get-BPProfiles $d
        $b = Get-BPBaiyangItem $p
        if (-not $b) { return $false }
        $src = Join-Path $d "profiles\$($b.File)"
        if (-not (Test-Path -LiteralPath $file) -and (Test-Path -LiteralPath $src)) { Copy-Item -LiteralPath $src -Destination $file -Force }
        $m = [ordered]@{ url = $b.Url; host = ([regex]::Match($b.Url, '^https?://([^/]+)')).Groups[1].Value; updated = (Get-Date).ToString('o'); from = 'clash-verge' }
        for ($i = $b.Start; $i -le $b.End; $i++) {
            if ($p.Lines[$i] -match '^    (upload|download|total|expire):\s*(\d+)') { $m[$Matches[1]] = [double]$Matches[2] }
        }
        Save-BCSubMeta 'baiyang' $m
        return $true
    } catch { return $false }
}

function Update-BCSubscription {
    # 拉取白羊订阅到 core\sub\baiyang.yaml；返回结构与 Update-BPSubscription 相同
    $r = Invoke-BPGuardJson @('sub-update')
    if ($r -and ($r.ok -or [string]$r.message -notmatch 'TLS')) { return $r }
    return (Update-BCSubscriptionPS)
}

function Update-BCSubscriptionPS {
    $res =[ordered]@{ ok = $false; changed = $false; nodeChanged = $false; pinMissing = $false; host = ''; message = '' }
    [void](Initialize-BCSub)
    $meta = Get-BCSubMeta 'baiyang'
    if (-not $meta -or -not $meta.url) { $res.message = '没有找到白羊订阅地址（请先在白羊加速或 Clash Verge 里导入一次订阅）'; return [pscustomobject]$res }
    $f = Invoke-BPFetchSub ([string]$meta.url)
    if (-not $f.content) { $res.message = $f.error; return [pscustomobject]$res }
    $file = Get-BCSubFile 'baiyang'
    $old = Read-BPText $file
    $pin = Get-BPPinnedNode
    $newNode = Find-BPNode $f.content $pin
    $oldEp = Get-BPNodeEndpoint (Find-BPNode $old $pin)
    $newEp = Get-BPNodeEndpoint $newNode
    $res.ok = $true; $res.host = $f.host
    $res.pinMissing = (-not $newNode)
    $res.changed = ($f.content -ne $old)
    $res.nodeChanged = ($oldEp -ne $newEp)
    if ($res.changed) { Write-BPText $file $f.content }
    $m = [ordered]@{ url = ([string]$meta.url -replace '^(https?://)[^/]+', ('${1}' + $f.host)); host = $f.host; updated = (Get-Date).ToString('o'); from = 'claude-guard' }
    $ui = ConvertFrom-BCUserInfo $f.userinfo
    foreach ($k in @('upload', 'download', 'total', 'expire')) { if ($ui.Contains($k)) { $m[$k] = $ui[$k] } elseif ($meta.$k) { $m[$k] = $meta.$k } }
    Save-BCSubMeta 'baiyang' $m
    $portOld = ($oldEp -split ':')[-1]; $portNew = ($newEp -split ':')[-1]
    if ($res.pinMissing) { $res.message = ('订阅已更新，但里面已经没有锁定的节点「{0}」，请在「配置与订阅」里改锁其他节点' -f $pin.name) }
    elseif ($res.nodeChanged) { $res.message = "锁定节点入口已变化（端口 $portOld → $portNew），已写入新订阅" }
    elseif ($res.changed) { $res.message = "订阅已更新，锁定节点入口未变（端口 $portNew）" }
    else { $res.message = "订阅已是最新，锁定节点入口未变（端口 $portNew）" }
    return [pscustomobject]$res
}

function Import-BCLocal([string]$Path) {
    # 导入本地 Clash 配置（yaml）作为节点来源；只取其中的节点，规则一律用本程序的严格规则
    if (-not (Test-Path -LiteralPath $Path)) { throw "文件不存在：$Path" }
    $t = Read-BPText $Path
    if ($t.Length -gt 20MB) { throw '文件太大，不像是 Clash 配置' }
    $nodes = @(Get-BPNodeList $t)
    if ($nodes.Count -eq 0) { throw '文件里没有找到可用节点（需要是带 proxies: 的 Clash/mihomo 配置文件）' }
    Initialize-BCDirsUser
    Write-BPText (Get-BCSubFile 'local') $t
    Save-BCSubMeta 'local' ([ordered]@{ name = (Split-Path $Path -Leaf); source = $Path; nodes = $nodes.Count; updated = (Get-Date).ToString('o') })
    return $nodes.Count
}

function Initialize-BCDirsUser {
    # 普通用户：sub 目录应已由安装程序创建并放开写权限
    if (-not (Test-Path -LiteralPath $script:BC_SubDir)) { throw '内置引擎尚未安装（缺少 core\sub 目录），请先在「维护」里更新到最新版' }
}

# ------------------------------------------------------------------ 生成运行配置
function ConvertTo-BCYamlString([string]$s) { return '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"' }

function Get-BCNodeEntry([string]$Text, $Node) {
    # 从订阅里取出该节点的完整定义，返回可直接放在 proxies: 下的 YAML（2 空格缩进），并强制 udp: true
    $lines = $Text -split "`r?`n"
    $inProxies = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match '^([A-Za-z0-9_-]+):') { $inProxies = ($Matches[1] -eq 'proxies'); continue }
        if (-not $inProxies) { continue }
        if ($l -match '^\s*-\s*\{(.*)\}\s*$') {
            $body = $Matches[1]
            $nm = ''
            if ($body -match '(?:^|,)\s*name:\s*(?:"([^"]*)"|''([^'']*)''|([^,]+?))\s*(?:,|$)') { $nm = ($Matches[1] + $Matches[2] + $Matches[3]).Trim() }
            if ($nm -ne $Node.name) { continue }
            if ($body -match '(?:^|,)\s*udp:\s*\w+') { $body = [regex]::Replace($body, '((?:^|,)\s*udp:\s*)\w+', '${1}true') }
            else { $body = $body.TrimEnd() + ', udp: true' }
            return ('  - {' + $body + '}')
        }
        if ($l -match '^(\s*)-\s+name:\s*(.+?)\s*$') {
            $ind = $Matches[1].Length; $nm = $Matches[2].Trim('"', "'")
            if ($nm -ne $Node.name) { continue }
            $block = New-Object System.Collections.Generic.List[string]
            $block.Add($l.Substring($ind))
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                $x = $lines[$j]
                if (-not $x.Trim()) { continue }
                $xi = $x.Length - $x.TrimStart().Length
                if ($xi -le $ind) { break }
                $block.Add($x.Substring($ind))
            }
            $hasUdp = $false
            for ($k = 1; $k -lt $block.Count; $k++) { if ($block[$k] -match '^  udp:') { $block[$k] = '  udp: true'; $hasUdp = $true } }
            if (-not $hasUdp) { $block.Add('  udp: true') }
            return (($block | ForEach-Object { '  ' + $_ }) -join "`n")
        }
    }
    return $null
}

function New-BCConfigText($S = $null, $Pin = $null, $SubText = $null) {
    # 返回 @{ text; node; missing }。锁定节点不在订阅里 → 0 个节点 + 全部拒绝（宁可全断，也不换别的出口）
    # 注意：$SubText 不能声明为 [string]，否则 $null 会被转换成 ''，导致永远不读订阅（v8/v9.0 的 bug）
    if (-not $S) { $S = Get-BCSettings }
    if (-not $Pin) { $Pin = Get-BPPinnedNode }
    if ([string]::IsNullOrEmpty([string]$SubText)) { $SubText = Get-BCSubText ([string]$S.subSource) }
    $SubText = [string]$SubText
    $node = Find-BPNode $SubText $Pin
    $entry = $(if ($node) { Get-BCNodeEntry $SubText $node } else { $null })
    $tun = ([string]$S.netMode -ne 'sysproxy')
    $G = $script:BC_Group
    $secret = [string]$S.secret
    $sb = New-Object System.Text.StringBuilder
    $add = { param($x) [void]$sb.Append($x).Append("`n") }

    & $add '# 由「Claude保护」内置引擎自动生成，请勿手动修改（开启保护 / 更新订阅 / 切换节点时会重新生成）'
    & $add ('# 锁定节点：{0}' -f $(if ($node) { $node.name } else { '（订阅里找不到，已全部拒绝）' }))
    & $add ('mixed-port: {0}' -f [int]$S.mixedPort)
    & $add 'allow-lan: false'
    & $add 'bind-address: 127.0.0.1'
    & $add 'mode: rule'
    & $add 'log-level: warning'
    & $add 'ipv6: false'
    & $add ('external-controller: 127.0.0.1:{0}' -f [int]$S.apiPort)
    & $add ('secret: {0}' -f (ConvertTo-BCYamlString $secret))
    & $add 'unified-delay: true'
    & $add 'tcp-concurrent: true'
    & $add 'keep-alive-idle: 30'
    & $add 'keep-alive-interval: 15'
    & $add 'find-process-mode: off'
    & $add 'geo-auto-update: false'
    & $add 'profile:'
    & $add '  store-selected: false'
    & $add '  store-fake-ip: false'
    & $add 'hosts: {}'
    & $add 'sniffer:'
    & $add '  enable: false'
    & $add 'ntp:'
    & $add '  enable: false'
    & $add 'tun:'
    & $add ('  enable: {0}' -f $(if ($tun) { 'true' } else { 'false' }))
    & $add ('  device: {0}' -f $script:BC_TunName)
    & $add ('  inet4-address: [{0}]' -f $script:BC_TunAddr)
    & $add '  stack: mixed'
    & $add '  mtu: 1360'
    & $add '  auto-route: true'
    & $add '  auto-detect-interface: true'
    & $add '  strict-route: true'
    & $add '  dns-hijack: ["any:53", "tcp://any:53"]'
    & $add 'dns:'
    & $add '  enable: true'
    & $add ('  listen: 127.0.0.1:{0}' -f [int]$S.dnsPort)
    & $add '  ipv6: false'
    & $add '  prefer-h3: false'
    & $add '  enhanced-mode: fake-ip'
    & $add ('  fake-ip-range: {0}' -f $script:BC_FakeIpRange)
    & $add '  fake-ip-filter-mode: blacklist'
    & $add '  fake-ip-filter: ["*.lan", "*.local", "*.localhost", "*.arpa", "*.test", "+.msftconnecttest.com", "+.msftncsi.com"]'
    & $add '  respect-rules: false'
    & $add '  use-hosts: false'
    & $add '  use-system-hosts: false'
    & $add '  default-nameserver: ["https://223.5.5.5/dns-query", "https://1.12.12.12/dns-query"]'
    & $add '  proxy-server-nameserver: ["https://223.5.5.5/dns-query", "https://1.12.12.12/dns-query"]'
    & $add '  direct-nameserver: ["https://223.5.5.5/dns-query", "https://1.12.12.12/dns-query"]'
    if ($entry) {
        & $add ('  nameserver: ["https://1.1.1.1/dns-query#{0}", "https://8.8.8.8/dns-query#{0}"]' -f $G)
        & $add 'proxies:'
        & $add $entry
        & $add 'proxy-groups:'
        & $add ('  - {{ name: {0}, type: select, proxies: [{1}] }}' -f $G, (ConvertTo-BCYamlString $node.name))
        & $add 'rules:'
        foreach ($r in @(
            # 局域网（不会出境）
            'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve', 'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve', 'IP-CIDR,172.16.0.0/12,DIRECT,no-resolve',
            'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve', 'IP-CIDR,169.254.0.0/16,DIRECT,no-resolve', 'IP-CIDR,224.0.0.0/4,DIRECT,no-resolve',
            'IP-CIDR,255.255.255.255/32,DIRECT,no-resolve',
            # 订阅自愈：仅白羊订阅 API 域名 + 官方镜像发现地址直连（入口端口变了也能拉到新订阅）
            'DOMAIN-SUFFIX,baiyang888.xyz,DIRECT', 'DOMAIN-SUFFIX,czzpp.cn,DIRECT', 'DOMAIN-SUFFIX,j396.com,DIRECT', 'DOMAIN-SUFFIX,smirsb.cn,DIRECT',
            'DOMAIN,byang.oss-ap-southeast-1.aliyuncs.com,DIRECT',
            # 开发镜像白名单：仅国内 Docker / npm / Maven / pip / apt 镜像主机直连（与 Claude 无关）
            'DOMAIN-SUFFIX,m.daocloud.io,DIRECT', 'DOMAIN-SUFFIX,1ms.run,DIRECT', 'DOMAIN,ccr.ccs.tencentyun.com,DIRECT',
            'DOMAIN,mirror.ccs.tencentyun.com,DIRECT', 'DOMAIN,registry.npmmirror.com,DIRECT', 'DOMAIN,cdn.npmmirror.com,DIRECT',
            'DOMAIN,maven.aliyun.com,DIRECT', 'DOMAIN,mirrors.aliyun.com,DIRECT',
            'DOMAIN-SUFFIX,cloud.tencent.com,DIRECT', 'DOMAIN-SUFFIX,qcloud.com,DIRECT', 'DOMAIN-SUFFIX,qcloudimg.com,DIRECT', 'DOMAIN-SUFFIX,myqcloud.com,DIRECT', 'DOMAIN-SUFFIX,tencentcloudapi.com,DIRECT', 'DOMAIN-SUFFIX,tencent-cloud.com,DIRECT', 'DOMAIN-SUFFIX,tencent-cloud.net,DIRECT', 'DOMAIN-SUFFIX,tencent-cloud.cn,DIRECT',
            # 屏蔽 QUIC：节点是 TCP 隧道，QUIC 塞进去遇丢包会严重卡顿，拒绝后浏览器自动改走 TCP
            'AND,((NETWORK,UDP),(DST-PORT,443)),REJECT',
            # 纯遥测（绝不含 statsig，它是 Claude 登录鉴权所需）
            'DOMAIN-SUFFIX,datadoghq.com,REJECT', 'DOMAIN-SUFFIX,segment.io,REJECT', 'DOMAIN-SUFFIX,cdn.usefathom.com,REJECT',
            # 其余全部走锁定的节点；节点不通就是断网，不回落
            ('MATCH,' + $G))) { & $add ('  - ' + $r) }
    } else {
        & $add '  nameserver: ["https://1.1.1.1/dns-query"]'
        & $add 'proxies: []'
        & $add 'proxy-groups: []'
        & $add 'rules:'
        foreach ($r in @('IP-CIDR,127.0.0.0/8,DIRECT,no-resolve', 'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve', 'IP-CIDR,172.16.0.0/12,DIRECT,no-resolve',
                         'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve', 'MATCH,REJECT')) { & $add ('  - ' + $r) }
    }
    return [pscustomobject]@{ text = $sb.ToString(); node = $node; missing = (-not $entry) }
}

function Test-BCConfigFile([string]$Path, [string]$Exe = '') {
    # 用内核自带的 -t 校验配置；返回 @{ ok; output }
    if (-not $Exe) { $Exe = $script:BC_Exe }
    if (-not (Test-Path -LiteralPath $Exe)) { $Exe = Get-BCVergeCoreSource }
    if (-not $Exe) { return [pscustomobject]@{ ok = $false; output = '找不到内核程序' } }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo($Exe, ('-t -d "{0}" -f "{1}"' -f (Split-Path $Path -Parent), $Path))
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $o = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
        [void]$p.WaitForExit(20000)
        return [pscustomobject]@{ ok = ($o -match 'test is successful'); output = $o.Trim() }
    } catch { return [pscustomobject]@{ ok = $false; output = $_.Exception.Message } }
}

function Test-BCRuntimeText([string]$Text) {
    # 与守护相同的核对：恰好 1 个节点 + MATCH,KR-ONLY + 无自动测速组
    $section = ''; $n = 0
    foreach ($l in ($Text -split "`r?`n")) {
        if ($l -match '^([A-Za-z0-9_-]+):') { $section = $Matches[1] }
        if ($section -eq 'proxies' -and ($l -match '^\s*-\s+name:' -or $l -match '^\s*-\s*\{')) { $n++ }
    }
    return ($n -eq 1 -and $Text.Contains('MATCH,' + $script:BC_Group) -and $Text -notmatch 'type:\s*url-test')
}

function Update-BCRuntime([switch]$NoReload) {
    # 需要管理员/SYSTEM。按当前设置 + 锁定节点 + 订阅生成运行配置；有变化时先用内核校验，再替换并热重载
    # 返回 @{ ok; changed; reloaded; missing; message }
    $a = @('runtime'); if ($NoReload) { $a += '--no-reload' }
    $r = Invoke-BPGuardJson $a
    # 内核判定新配置无效时 PowerShell 版结果相同，直接返回；其他失败改用 PowerShell 版
    if ($r -and ($r.ok -or [string]$r.message -like '新配置校验失败*')) { return $r }
    return (Update-BCRuntimePS -NoReload:$NoReload)
}

function Update-BCRuntimePS([switch]$NoReload) {
    $res =[ordered]@{ ok = $false; changed = $false; reloaded = $false; missing = $false; message = '' }
    Initialize-BCDirs
    $S = Get-BCSettings
    if (-not $S.secret) { Save-BCSettings $S; $S = Get-BCSettings }
    $g = New-BCConfigText $S
    $res.missing = [bool]$g.missing
    $old = Read-BPText $script:BC_Config
    if ($old -eq $g.text) { $res.ok = $true; $res.message = '运行配置无变化'; return [pscustomobject]$res }
    $tmp = Join-Path $script:BC_Home 'config.new.yaml'
    Write-BPText $tmp $g.text
    $t = Test-BCConfigFile $tmp
    if (-not $t.ok) {
        $res.message = '新配置校验失败，保持原配置：' + ((@($t.output -split "`n") | Select-Object -Last 2) -join ' ')
        return [pscustomobject]$res
    }
    Move-Item -LiteralPath $tmp -Destination $script:BC_Config -Force
    $res.ok = $true; $res.changed = $true
    $res.message = $(if ($g.missing) { '订阅里没有锁定的节点，运行配置已改为全部拒绝' } else { '运行配置已更新（{0}）' -f $g.node.name })
    if (-not $NoReload -and (Get-BCCoreProcess)) {
        try {
            $body = (@{ path = $script:BC_Config } | ConvertTo-Json -Compress)
            [void](Invoke-BCApi 'PUT' '/configs?force=true' $body)
            $res.reloaded = $true; $res.message += '，内核已热重载'
        } catch { $res.message += '，热重载失败：' + $_.Exception.Message }
    }
    return [pscustomobject]$res
}

# ------------------------------------------------------------------ 内核进程 / 计划任务 / 控制接口
function Get-BCCoreProcess {
    return @([System.Diagnostics.Process]::GetProcessesByName($script:BC_ProcName))
}

function Get-BCTaskArgument {
    # cmd /c 的引号规则：参数里引号超过两个时，cmd 会去掉第一个和最后一个引号，命令被拆坏（v8~v9.1 内核因此从未启动）。
    # 正确写法是整条命令外面再包一层引号：/c ""exe" -d "dir" ... >> "log" 2>&1"
    return ('/c ""{0}" -d "{1}" -f "{2}" >> "{3}" 2>&1"' -f $script:BC_Exe, $script:BC_Home, $script:BC_Config, $script:BC_LogFile)
}

function Get-BCCoreLogTail([int]$Lines = 3) {
    # 内核日志最后几行（启动失败时给出真实原因）；去掉 ANSI 颜色码
    try {
        if (-not [IO.File]::Exists($script:BC_LogFile)) { return '内核没有写出任何日志（进程没有被启动）' }
        $t = @(Get-Content -LiteralPath $script:BC_LogFile -Tail $Lines -Encoding UTF8 | ForEach-Object { ($_ -replace '\x1b\[[0-9;]*m', '').Trim() } | Where-Object { $_ })
        if ($t.Count -eq 0) { return '内核日志为空' }
        return ($t -join ' | ')
    } catch { return '' }
}

function Register-BCTask {
    # SYSTEM 身份运行（TUN 需要管理员权限）；开机自启只在保护开启期间启用
    $cmd = Get-BCTaskArgument
    $action    = New-ScheduledTaskAction -Execute (Join-Path $env:windir 'System32\cmd.exe') -Argument $cmd -WorkingDirectory $script:BC_Root
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount
    $settings  = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $script:BC_TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}

function Start-BCCore {
    # 需要管理员。已在运行则不重复启动。Rust 版不注册任务：任务不存在 / 是旧版注册的时，由下面的 PowerShell 代码重新注册
    if (Get-BCCoreProcess) { return $true }
    $r = Invoke-BPGuardJson @('core-start')
    if ($r -and $r.ok) { return $true }
    try {
        if ((Test-Path -LiteralPath $script:BC_LogFile) -and (Get-Item -LiteralPath $script:BC_LogFile).Length -gt 2MB) {
            Move-Item -LiteralPath $script:BC_LogFile -Destination ($script:BC_LogFile + '.1') -Force
        }
    } catch {}
    # 任务不存在，或是旧版本注册的（命令行不对）→ 重新注册
    $task = Get-ScheduledTask -TaskName $script:BC_TaskName -ErrorAction SilentlyContinue
    if (-not $task -or [string]$task.Actions[0].Arguments -ne (Get-BCTaskArgument)) { Register-BCTask }
    Enable-ScheduledTask -TaskName $script:BC_TaskName -ErrorAction SilentlyContinue | Out-Null
    Start-ScheduledTask -TaskName $script:BC_TaskName
    return $true
}

function Stop-BCCore([switch]$Disable) {
    # 需要管理员。停止计划任务并结束内核进程（TUN 网卡随内核一起消失）
    $a = @('core-stop'); if ($Disable) { $a += '--disable' }
    $r = Invoke-BPGuardJson $a
    if ($r -and $r.ok) { return $true }
    try { Stop-ScheduledTask -TaskName $script:BC_TaskName -ErrorAction SilentlyContinue } catch {}
    if ($Disable) { try { Disable-ScheduledTask -TaskName $script:BC_TaskName -ErrorAction SilentlyContinue | Out-Null } catch {} }
    foreach ($p in (Get-BCCoreProcess)) { try { $p.Kill() } catch {} }
    for ($i = 0; $i -lt 20 -and (Get-BCCoreProcess); $i++) { Start-Sleep -Milliseconds 250 }
    return (-not (Get-BCCoreProcess))
}

function Invoke-BCApi([string]$Method, [string]$Path, [string]$Body = $null, [int]$TimeoutMs = 4000) {
    $S = Get-BCSettings
    $req = [System.Net.HttpWebRequest]::Create(('http://127.0.0.1:{0}{1}' -f [int]$S.apiPort, $Path))
    $req.Method = $Method; $req.Proxy = $null; $req.Timeout = $TimeoutMs; $req.ReadWriteTimeout = $TimeoutMs
    if ($S.secret) { $req.Headers['Authorization'] = 'Bearer ' + [string]$S.secret }
    if ($Body) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentType = 'application/json'; $req.ContentLength = $bytes.Length
        $rs = $req.GetRequestStream(); $rs.Write($bytes, 0, $bytes.Length); $rs.Close()
    }
    $resp = $req.GetResponse()
    try { $sr = New-Object System.IO.StreamReader($resp.GetResponseStream()); $t = $sr.ReadToEnd(); $sr.Close() } finally { $resp.Close() }
    if ($t -and $t.TrimStart().StartsWith('{')) { return ($t | ConvertFrom-Json) }
    return $t
}

function Wait-BCNodeWorks([int]$TimeoutSec = 15) {
    # 让内置内核经锁定的节点真实请求一次（内核自带的延迟测试），确认“节点真的通”而不只是“内核启动了”。
    # 返回 @{ ok; ms; error }
    $url = [Uri]::EscapeDataString('https://www.gstatic.com/generate_204')
    $path = '/proxies/{0}/delay?timeout=5000&url={1}' -f [Uri]::EscapeDataString($script:BC_Group), $url
    $sw = [Diagnostics.Stopwatch]::StartNew(); $err = ''
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try {
            $r = Invoke-BCApi 'GET' $path $null 7000
            if ($r -and [int]$r.delay -gt 0) { return [pscustomobject]@{ ok = $true; ms = [int]$r.delay; error = '' } }
            $err = '延迟测试没有结果'
        } catch {
            $err = $_.Exception.Message
            try { $b = (New-Object IO.StreamReader($_.Exception.InnerException.Response.GetResponseStream())).ReadToEnd(); if ($b) { $err = $b.Trim() } } catch {}
        }
        Start-Sleep -Milliseconds 800
    }
    return [pscustomobject]@{ ok = $false; ms = 0; error = $err }
}

function Test-BCApi { try { $v = Invoke-BCApi 'GET' '/version' $null 1500; return [bool]($v -and $v.version) } catch { return $false } }

function Get-BCTunInfo {
    $r = [ordered]@{ up = $false; addr = '' }
    try {
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.Name -ne $script:BC_TunName) { continue }
            $r.up = ($ni.OperationalStatus -eq 'Up')
            foreach ($a in $ni.GetIPProperties().UnicastAddresses) { if ($a.Address.AddressFamily -eq 'InterNetwork') { $r.addr = $a.Address.ToString() } }
        }
    } catch {}
    return [pscustomobject]$r
}

# ------------------------------------------------------------------ 冲突检测（其他 Clash / 白羊 App）
function Get-BCConflicts {
    # 返回正在运行、会与内置引擎冲突的程序与网卡（只读）
    $out = @()
    foreach ($n in @('clash-verge', 'verge-mihomo', 'verge-mihomo-alpha', 'clash-meta', 'mihomo', 'clash', 'baiyang')) {
        foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
            $label = switch -Regex ($n) { '^clash-verge$' { 'Clash Verge 界面' } '^verge-mihomo' { 'Clash Verge 内核' } '^baiyang$' { '白羊加速 App' } default { 'Clash 内核' } }
            $out += [pscustomobject]@{ kind = 'process'; name = $label; detail = ('{0}.exe PID {1}' -f $n, $p.Id); pid = $p.Id }
        }
    }
    try {
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.Name -eq $script:BC_TunName -or $ni.OperationalStatus -ne 'Up') { continue }
            if ($ni.Name -match '^(Mihomo|Meta|Clash|utun)' -or $ni.Description -match 'Mihomo|Meta Tunnel|Clash') {
                $out += [pscustomobject]@{ kind = 'tun'; name = ('其他 Clash 的 TUN 网卡「{0}」' -f $ni.Name); detail = $ni.Description; pid = 0 }
            }
        }
    } catch {}
    return $out
}

function Stop-BCConflicts {
    # 需要管理员（Clash Verge 内核由它的系统服务以 SYSTEM 身份启动）。只结束界面与内核，不卸载、不改它们的配置
    $names = @('baiyang', 'clash-verge', 'verge-mihomo', 'verge-mihomo-alpha', 'clash-meta', 'mihomo', 'clash')
    foreach ($n in $names) { Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    foreach ($n in $names) { Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
    return @(Get-BCConflicts | Where-Object { $_.kind -eq 'process' }).Count
}

# ------------------------------------------------------------------ 守护配置跟随引擎
function Set-BCGuardEngine([string]$Engine, [string]$NetMode = 'tun') {
    # 需要管理员。改写 guard.config.json 里与引擎相关的字段；返回是否有改动
    $f = Join-Path $script:BP_GuardRoot 'guard.config.json'
    $c = $(if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } else { New-Object psobject })
    $before = ($c | ConvertTo-Json -Depth 6 -Compress)
    $set = { param($k, $v) if ($c.PSObject.Properties.Name -contains $k) { $c.$k = $v } else { $c | Add-Member -NotePropertyName $k -NotePropertyValue $v } }
    $isOurs = { param($p) ([string]$p) -like ($script:BC_Root + '*') }
    # 记住 Clash Verge 的路径（切回旧引擎时用）
    $roots = @($c.coreRoots | Where-Object { $_ -and -not (& $isOurs $_) })
    if ($roots.Count -gt 0) { & $set 'vergeCoreRoots' $roots }
    if ($c.runtimeYaml -and -not (& $isOurs $c.runtimeYaml)) { & $set 'vergeRuntimeYaml' ([string]$c.runtimeYaml) }
    if ($Engine -eq 'builtin') {
        & $set 'engine' 'builtin'
        & $set 'netMode' $(if ($NetMode -eq 'sysproxy') { 'sysproxy' } else { 'tun' })
        & $set 'coreRoots' @($script:BC_Root)
        & $set 'coreNames' @('cg-mihomo.exe')
        & $set 'coreDiscovery' $false
        & $set 'runtimeYaml' $script:BC_Config
        & $set 'tunAlias' $script:BC_TunName
        & $set 'tunLocalCidr' $script:BC_TunCidr
        & $set 'probeProxy' ('http://127.0.0.1:{0}' -f [int](Get-BCSettings).mixedPort)
    } else {
        $vr = @($c.vergeCoreRoots | Where-Object { $_ }); if ($vr.Count -eq 0) { $vr = @($script:BC_VergeDefaultDir) }
        # 服务模式下内核实际从 clash-verge-service\cores 运行：一并放行，切换时不用等守护自动发现
        if ([IO.Directory]::Exists($script:BC_VergeServiceCores) -and ($vr -notcontains $script:BC_VergeServiceCores)) { $vr += $script:BC_VergeServiceCores }
        $vy = [string]$c.vergeRuntimeYaml; if (-not $vy) { $vy = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml' }
        & $set 'engine' 'verge'
        & $set 'netMode' 'tun'
        & $set 'coreRoots' $vr
        & $set 'coreNames' @('verge-mihomo.exe', 'verge-mihomo-alpha.exe')
        & $set 'coreDiscovery' $true
        & $set 'runtimeYaml' $vy
        & $set 'tunAlias' 'Mihomo'
        & $set 'tunLocalCidr' '198.18.0.0/24'
        & $set 'probeProxy' ''
    }
    $after = ($c | ConvertTo-Json -Depth 6 -Compress)
    if ($after -eq $before) { return $false }
    [IO.File]::WriteAllText($f, ($c | ConvertTo-Json -Depth 6), $script:BP_Utf8)
    return $true
}

# ------------------------------------------------------------------ 系统代理（当前用户，控制台以普通用户身份调用）
$script:BC_InetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
function Get-BCSysProxy {
    try {
        $k = Get-ItemProperty -LiteralPath $script:BC_InetKey -ErrorAction Stop
        return [pscustomobject]@{ enabled = ([int]$k.ProxyEnable -eq 1); server = [string]$k.ProxyServer; bypass = [string]$k.ProxyOverride }
    } catch { return [pscustomobject]@{ enabled = $false; server = ''; bypass = '' } }
}

function Set-BCSysProxy([bool]$On, [int]$Port = 0) {
    if (-not $Port) { $Port = [int](Get-BCSettings).mixedPort }
    if ($On) {
        Set-ItemProperty -LiteralPath $script:BC_InetKey -Name ProxyServer -Value ('127.0.0.1:{0}' -f $Port)
        Set-ItemProperty -LiteralPath $script:BC_InetKey -Name ProxyOverride -Value 'localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>'
        Set-ItemProperty -LiteralPath $script:BC_InetKey -Name ProxyEnable -Value 1 -Type DWord
    } else {
        Set-ItemProperty -LiteralPath $script:BC_InetKey -Name ProxyEnable -Value 0 -Type DWord
    }
    try {
        if (-not ('CG.BCWinInet' -as [type])) {
            Add-Type -Namespace 'CG' -Name 'BCWinInet' -MemberDefinition '[DllImport("wininet.dll", SetLastError=true)] public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);'
        }
        [void][CG.BCWinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)   # SETTINGS_CHANGED
        [void][CG.BCWinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)   # REFRESH
    } catch {}
}

function Test-BCSysProxyOurs {
    $p = Get-BCSysProxy
    return ($p.enabled -and $p.server -match ('^(http=)?127\.0\.0\.1:{0}$' -f [int](Get-BCSettings).mixedPort))
}

# ------------------------------------------------------------------ 热切换（保护开启时切换引擎 / 接管方式 / 节点）
# 防火墙内核放行规则按程序路径命名（与 ClaudeGuard.ps1 的 Get-CoreRuleName 必须一致），这样可以“先加新、后删旧”，切换时不出现放行空档
function Get-BCRuleName([string]$Path) {
    $h = [BitConverter]::ToString((New-Object Security.Cryptography.SHA1Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant()))).Replace('-', '').Substring(0, 10)
    return ('ClaudeGuard-Allow-Core-' + $h)
}

function Get-BCFwRuleRaw {
    # name -> 规则定义字符串（直接读注册表，毫秒级）
    $map = @{}
    try { $k = Get-Item -LiteralPath $script:BC_FwRulesKey -ErrorAction Stop; foreach ($n in $k.GetValueNames()) { if ($n -like 'ClaudeGuard-*') { $map[$n] = [string]$k.GetValue($n) } } } catch {}
    return $map
}

function Get-BCVergeCorePaths {
    # Clash Verge 内核可能运行的位置（安装目录 + 服务目录 + 正在运行的进程），只返回存在的文件
    $roots = @()
    try {
        $c = Get-Content -LiteralPath (Join-Path $script:BP_GuardRoot 'guard.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $roots += @($c.vergeCoreRoots) + @($c.coreRoots)
    } catch {}
    $roots += @($script:BC_VergeDefaultDir, "$env:ProgramFiles\Clash Verge", $script:BC_VergeServiceCores)
    $set = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in ($roots | Where-Object { $_ -and -not ([string]$_).StartsWith($script:BC_Root, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -Unique)) {
        foreach ($n in @('verge-mihomo.exe', 'verge-mihomo-alpha.exe')) { $x = Join-Path $r $n; if ([IO.File]::Exists($x)) { [void]$set.Add($x) } }
    }
    try { foreach ($p in @(Get-Process -Name 'verge-mihomo', 'verge-mihomo-alpha' -ErrorAction SilentlyContinue)) { if ($p.Path) { [void]$set.Add($p.Path) } } } catch {}
    return @($set)
}

function Get-BCGuardExe {
    # 7.2 起的 cg-guard.exe 能原生修改防火墙规则（不经 PowerShell 防火墙模块）；没有或版本太旧时返回空
    return (Get-BPGuardExe 2)
}

function Add-BCTransitionAllow([string[]]$Programs, [string[]]$Cidrs) {
    # 需要管理员。切换期间临时多放行一个内核 / 一段 TUN 地址（只加不删；切换完成后由守护按新配置收回多余的规则）
    $exe = Get-BCGuardExe
    if ($exe) {
        $a = @('allow')
        foreach ($p in @($Programs | Where-Object { $_ })) { $a += @('--program', $p) }
        foreach ($c in @($Cidrs | Where-Object { $_ } | Select-Object -Unique)) { $a += @('--cidr', $c) }
        & $exe @a | Out-Null
        if ($LASTEXITCODE -eq 0) { return }
        # 原生方式没成功：下面用 PowerShell 再做一遍（只补缺的）
    }
    $raw = Get-BCFwRuleRaw
    foreach ($p in @($Programs | Where-Object { $_ })) {
        $n = Get-BCRuleName $p
        if ($raw.ContainsKey($n)) { continue }
        New-NetFirewallRule -Name $n -DisplayName ('ClaudeGuard 内核 TCP {0}' -f (Split-Path $p -Leaf)) -Group 'ClaudeGuard' -Profile Any -Enabled True `
            -Direction Outbound -Action Allow -Program $p -Protocol TCP | Out-Null
    }
    $cidrs = @($Cidrs | Where-Object { $_ } | Select-Object -Unique)
    if ($cidrs.Count -gt 0 -and $raw.ContainsKey('ClaudeGuard-Allow-TUN')) {
        Set-NetFirewallRule -Name 'ClaudeGuard-Allow-TUN' -LocalAddress $cidrs | Out-Null
    }
}

function Set-BCSwitchMarker([int]$Seconds, [string]$Target) {
    # 告诉守护“正在切换”：期间内核/TUN 暂时缺失不触发拦截、不自动拉起内核（防火墙默认拒绝始终有效，不会泄露）
    $o = [ordered]@{ target = $Target; since = (Get-Date).ToString('o'); until = (Get-Date).AddSeconds($Seconds).ToString('o'); pid = $PID }
    [IO.File]::WriteAllText($script:BC_SwitchFile, ($o | ConvertTo-Json), $script:BP_Utf8)
}
function Clear-BCSwitchMarker { Remove-Item -LiteralPath $script:BC_SwitchFile -Force -ErrorAction SilentlyContinue }

function Write-BCProgress([int]$Step, [int]$Total, [string]$Text, [string]$SysProxy = '', [switch]$Done, [bool]$Ok = $true) {
    # 供控制台显示进度；SysProxy = bridge（指向内置内核）/ clear（关掉本机 127.0.0.1 代理）/ 空
    try {
        $o = [ordered]@{ ts = (Get-Date).ToString('o'); step = $Step; total = $Total; text = $Text; sysproxy = $SysProxy; done = [bool]$Done; ok = $Ok }
        [IO.File]::WriteAllText($script:BC_ProgressFile, ($o | ConvertTo-Json), $script:BP_Utf8)
    } catch {}
}

function Wait-BCCoreReady([string]$NetMode, [int]$TimeoutSec = 30) {
    # 内核进程 + 控制接口 + （TUN 模式）网卡 ClaudeGuard 地址 198.19.0.x；返回是否就绪
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if (@(Get-BCCoreProcess).Count -gt 0 -and (Test-BCApi)) {
            if ($NetMode -eq 'sysproxy') { return $true }
            $ti = Get-BCTunInfo
            if ($ti.up -and $ti.addr.StartsWith('198.19.0.')) { return $true }
        }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Wait-BCTunGone([int]$TimeoutSec = 10) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) { if (-not (Get-BCTunInfo).up) { return $true }; Start-Sleep -Milliseconds 300 }
    return $false
}

function Get-BCRealProxies {
    # 内置内核实际加载的真实节点名称（不含 DIRECT/REJECT/策略组）
    $px = Invoke-BCApi 'GET' '/proxies'
    return @($px.proxies.PSObject.Properties | Where-Object { $_.Value.type -notin @('Direct', 'Reject', 'RejectDrop', 'Pass', 'PassRule', 'Compatible', 'Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Relay') } | ForEach-Object { $_.Name })
}

function Update-BCGuardConfigStamp {
    # 只更新时间戳，让守护重新读取配置并按配置收回多余的防火墙放行（切换失败回退时用）
    try { (Get-Item -LiteralPath (Join-Path $script:BP_GuardRoot 'guard.config.json')).LastWriteTime = Get-Date } catch {}
}

function Wait-BCGuardEngine([string]$Engine, [int]$TimeoutSec = 10) {
    # 等守护在状态里报告已切到新引擎（守护每 2 秒一个节拍，读到新配置后会同步防火墙）
    $f = Join-Path $script:BP_GuardRoot 'state\guard_state.json'
    $want = 0L; try { $want = (Get-Item -LiteralPath (Join-Path $script:BP_GuardRoot 'guard.config.json')).LastWriteTimeUtc.Ticks } catch {}
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try { $s = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json; if ([string]$s.engine -eq $Engine -and [int64]$s.cfgStamp -ge $want) { return $true } } catch {}
        Start-Sleep -Milliseconds 500
    }
    return $false
}
