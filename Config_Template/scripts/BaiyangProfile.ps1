<#
  BaiyangProfile.ps1 —— 白羊配置切换与订阅更新（被 Resume / Pause / 控制台 / 更新订阅脚本 dot-source 引用）

  · 严格配置：白羊订阅挂上 sRYohxTjB2to.js（只留韩国双ISP节点、零回落直连），TUN 全局、IPv6 关闭
  · 白羊原始配置：开启保护前自动保存的官方配置快照；没有快照时 = 取消挂载严格脚本（全部节点 + 官方规则）
  · 更新订阅：直接从白羊订阅接口拉取（含官方镜像发现），只有韩国节点的地址/端口变化时才需要重启 Clash
#>

$script:BP_StrictUid  = 'sRYohxTjB2to'
$script:BP_DefaultPinName  = 'V3-【双ISP家庭网络】韩国' + [char]::ConvertFromUtf32(0x1F1F0) + [char]::ConvertFromUtf32(0x1F1F7)
$script:BP_DefaultPinFuzzy = @('双ISP', '韩国')
$script:BP_SubHosts   = @('baiyang.smirsb.cn', 'bnet.czzpp.cn', 'baiyangweb.j396.com', 'baiyang.baiyang888.xyz')
$script:BP_OssUrl     = 'https://byang.oss-ap-southeast-1.aliyuncs.com/baiyang.txt'
$script:BP_GuardRoot  = 'C:\ProgramData\ClaudeGuard'
$script:BP_SnapDir    = Join-Path $script:BP_GuardRoot 'baiyang-original'
$script:BP_PinFile    = Join-Path $script:BP_GuardRoot 'pinned-node.json'
$script:BP_Utf8       = New-Object System.Text.UTF8Encoding($false)

# ------------------------------------------------------------------ 锁定节点
$script:BP_CountryNames = [ordered]@{
    KR = '韩国'; JP = '日本'; HK = '香港'; TW = '台湾'; SG = '新加坡'; US = '美国'; GB = '英国'; DE = '德国'; FR = '法国'
    IN = '印度'; AU = '澳大利亚'; CA = '加拿大'; RU = '俄罗斯'; TR = '土耳其'; VN = '越南'; TH = '泰国'; MY = '马来西亚'
    PH = '菲律宾'; ID = '印尼'; AR = '阿根廷'; BR = '巴西'; NL = '荷兰'; IT = '意大利'; ES = '西班牙'; MO = '澳门'; CN = '中国'
    AE = '阿联酋'; IL = '以色列'; MX = '墨西哥'; CL = '智利'; ZA = '南非'; NG = '尼日利亚'; UA = '乌克兰'; PL = '波兰'; SE = '瑞典'
    FI = '芬兰'; DK = '丹麦'; NO = '挪威'; CH = '瑞士'; IE = '爱尔兰'; NZ = '新西兰'; PK = '巴基斯坦'; KZ = '哈萨克斯坦'
}
$script:BP_CountryAlias = @{ '印度尼西亚' = 'ID'; '台灣' = 'TW'; '日本东京' = 'JP' }
# Anthropic 不提供服务的常见地区：可以锁定，但 Claude 会拒绝访问
$script:BP_ClaudeUnsupported = @('CN', 'HK', 'MO', 'RU', 'BY', 'IR', 'KP', 'SY', 'CU')

function Get-BPCountryName([string]$Code) { if ($Code -and $script:BP_CountryNames.Contains($Code)) { return $script:BP_CountryNames[$Code] }; return $Code }

function Get-BPCountry([string]$Name) {
    # 优先按名称里的中文地区名识别（长名优先，如“印度尼西亚”先于“印度”）；
    # 没有中文地区名时再用旗帜 emoji（区域指示符）。例如「台湾🇨🇳」按名称识别为 TW。
    foreach ($a in $script:BP_CountryAlias.Keys) { if ($Name.Contains($a)) { return $script:BP_CountryAlias[$a] } }
    foreach ($k in ($script:BP_CountryNames.Keys | Sort-Object { - $script:BP_CountryNames[$_].Length })) {
        if ($Name.Contains($script:BP_CountryNames[$k])) { return $k }
    }
    $letters = ''
    for ($i = 0; $i -lt $Name.Length; $i++) {
        if ([char]::IsHighSurrogate($Name[$i]) -and $i + 1 -lt $Name.Length) {
            $cp = [char]::ConvertToUtf32($Name[$i], $Name[$i + 1]); $i++
            if ($cp -ge 0x1F1E6 -and $cp -le 0x1F1FF) { $letters += [char](65 + $cp - 0x1F1E6); if ($letters.Length -eq 2) { return $letters } }
            else { $letters = '' }
        } else { $letters = '' }
    }
    return ''
}

function Get-BPPinnedNode {
    try {
        if (Test-Path -LiteralPath $script:BP_PinFile) {
            $o = Get-Content -LiteralPath $script:BP_PinFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($o.name) { return [pscustomobject]@{ name = [string]$o.name; country = [string]$o.country; fuzzy = @($o.fuzzy | Where-Object { $_ }); since = [string]$o.since } }
        }
    } catch {}
    return [pscustomobject]@{ name = $script:BP_DefaultPinName; country = 'KR'; fuzzy = $script:BP_DefaultPinFuzzy; since = '' }
}

function Set-BPPinnedNode([string]$Name, [string]$Country) {
    # 需要管理员权限（写 ProgramData）；默认韩国节点保留模糊匹配，其他节点只认精确名称
    $fuzzy = @(); if ($Name -eq $script:BP_DefaultPinName) { $fuzzy = $script:BP_DefaultPinFuzzy }
    $o = [ordered]@{ name = $Name; country = $Country; fuzzy = $fuzzy; since = (Get-Date).ToString('o') }
    [IO.File]::WriteAllText($script:BP_PinFile, ($o | ConvertTo-Json), $script:BP_Utf8)
}

function Set-BPGuardCountry([string]$Country) {
    # 守护的期望出口国家跟随锁定节点（需要管理员权限）；返回是否有改动
    $f = Join-Path $script:BP_GuardRoot 'guard.config.json'
    if (-not (Test-Path -LiteralPath $f)) { return $false }
    $c = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$c.expectedCountry -eq $Country) { return $false }
    $c.expectedCountry = $Country
    $asns = @(); if ($Country -eq 'KR') { $asns = @(401783) }
    if ($c.PSObject.Properties.Name -contains 'allowedAsns') { $c.allowedAsns = $asns } else { $c | Add-Member -NotePropertyName allowedAsns -NotePropertyValue $asns }
    [IO.File]::WriteAllText($f, ($c | ConvertTo-Json -Depth 6), $script:BP_Utf8)
    return $true
}

function Get-BPNodeList([string]$Text) {
    # 解析订阅里的真实节点（支持 flow 与 block 两种 YAML 写法），过滤掉 127.0.0.1 之类的提示用假节点
    $nodes = @(); $inProxies = $false; $cur = $null
    $realTypes = '^(vless|vmess|trojan|ss|ssr|hysteria|hysteria2|tuic|wireguard|anytls|socks5|http|snell)$'
    $finish = {
        param($n)
        if ($n -and $n.name -and $n.server -and $n.type -match $realTypes -and $n.server -notmatch '^(127\.|localhost$|0\.0\.0\.0)') {
            $n.country = Get-BPCountry $n.name
            return $n
        }
        return $null
    }
    foreach ($l in ($Text -split "`r?`n")) {
        if ($l -match '^([A-Za-z0-9_-]+):') {
            if ($cur) { $x = & $finish $cur; if ($x) { $nodes += $x }; $cur = $null }
            $inProxies = ($Matches[1] -eq 'proxies'); continue
        }
        if (-not $inProxies) { continue }
        if ($l -match '^\s*-\s*\{(.*)\}\s*$') {
            $body = $Matches[1]
            $n = [pscustomobject]@{ name = ''; type = ''; server = ''; port = ''; country = '' }
            if ($body -match '(?:^|,)\s*name:\s*(?:"([^"]*)"|''([^'']*)''|([^,]+?))\s*(?:,|$)') { $n.name = ($Matches[1] + $Matches[2] + $Matches[3]).Trim() }
            if ($body -match '(?:^|,)\s*type:\s*([^,\s]+)') { $n.type = $Matches[1] }
            if ($body -match '(?:^|,)\s*server:\s*([^,\s]+)') { $n.server = $Matches[1].Trim('"', "'") }
            if ($body -match '(?:^|,)\s*port:\s*(\d+)') { $n.port = $Matches[1] }
            $x = & $finish $n; if ($x) { $nodes += $x }
            continue
        }
        if ($l -match '^\s*-\s+name:\s*(.+?)\s*$') {
            if ($cur) { $x = & $finish $cur; if ($x) { $nodes += $x } }
            $cur = [pscustomobject]@{ name = $Matches[1].Trim('"', "'"); type = ''; server = ''; port = ''; country = '' }
            continue
        }
        if ($cur) {
            if ($l -match '^\s+type:\s*(\S+)') { $cur.type = $Matches[1] }
            elseif ($l -match '^\s+server:\s*(\S+)') { $cur.server = $Matches[1].Trim('"', "'") }
            elseif ($l -match '^\s+port:\s*(\d+)') { $cur.port = $Matches[1] }
        }
    }
    if ($cur) { $x = & $finish $cur; if ($x) { $nodes += $x } }
    return $nodes
}

function Find-BPNode([string]$Text, $Pin = $null) {
    # 与规则脚本相同的匹配逻辑：先精确名称，再（如有）模糊关键字
    if (-not $Pin) { $Pin = Get-BPPinnedNode }
    $list = @(Get-BPNodeList $Text)
    foreach ($n in $list) { if ($n.name -eq $Pin.name) { return $n } }
    $fz = @($Pin.fuzzy | Where-Object { $_ })
    if ($fz.Count -gt 0) {
        foreach ($n in $list) { $hit = $true; foreach ($k in $fz) { if (-not $n.name.Contains($k)) { $hit = $false; break } }; if ($hit) { return $n } }
    }
    return $null
}

function Get-BPRenderedJs($Pin = $null) {
    # 严格规则脚本 = 模板 + 写入锁定节点；默认韩国节点时与模板完全一致
    if (-not $Pin) { $Pin = Get-BPPinnedNode }
    $tpl = Get-BPTemplateJs
    if (-not $tpl) { return $null }
    $t = [IO.File]::ReadAllText($tpl, [Text.Encoding]::UTF8)
    $fz = @($Pin.fuzzy | Where-Object { $_ })
    if ($Pin.name -eq $script:BP_DefaultPinName -and ($fz -join '|') -eq ($script:BP_DefaultPinFuzzy -join '|')) { return $t }
    $esc = { param($s) "'" + ($s -replace '\\', '\\' -replace "'", "\'") + "'" }
    $nameJs = & $esc $Pin.name
    $fuzzyJs = '[' + ((@($fz | ForEach-Object { & $esc $_ })) -join ', ') + ']'
    $t = [regex]::Replace($t, "(?m)^(\s*var PIN_NAME = ).*?;", { param($m) $m.Groups[1].Value + $nameJs + ';' })
    $t = [regex]::Replace($t, "(?m)^(\s*var PIN_FUZZY = ).*?;", { param($m) $m.Groups[1].Value + $fuzzyJs + ';' })
    return $t
}

function Get-BPDataDir {
    # 以守护配置里的运行配置路径为准（提权运行时 APPDATA 也指向同一用户）
    # 使用内置引擎时 runtimeYaml 指向内置内核，Clash Verge 的路径另存在 vergeRuntimeYaml
    try {
        $c = Get-Content -LiteralPath (Join-Path $script:BP_GuardRoot 'guard.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($rt in @([string]$c.vergeRuntimeYaml, [string]$c.runtimeYaml)) {
            if ($rt) { $d = Split-Path $rt -Parent; if (Test-Path -LiteralPath (Join-Path $d 'profiles.yaml')) { return $d } }
        }
    } catch {}
    return (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev')
}

function Get-BPTemplateJs {
    # 优先用与本模块同一套的模板（已安装：bin\strict-profile.js；套件内：..\profiles\sRYohxTjB2to.js）
    foreach ($p in @((Join-Path $PSScriptRoot 'strict-profile.js'),
                     (Join-Path $PSScriptRoot '..\profiles\sRYohxTjB2to.js'),
                     (Join-Path $PSScriptRoot 'Config_Template\profiles\sRYohxTjB2to.js'),
                     (Join-Path $script:BP_GuardRoot 'bin\strict-profile.js'))) {
        if (Test-Path -LiteralPath $p) { return (Resolve-Path -LiteralPath $p).Path }
    }
    return $null
}

function Read-BPText([string]$Path) { if (Test-Path -LiteralPath $Path) { return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) } return '' }
function Write-BPText([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, $script:BP_Utf8) }

# ------------------------------------------------------------------ Rust 版（cg-guard.exe）
# 7.3 起订阅拉取、运行配置生成、内核启停由 cg-guard.exe 原生完成（与本文件逐字节一致，已对比验证）。
# 没有 cg-guard、版本太旧、它自己改用了 PowerShell（环境变量 CG_NO_NATIVE）或运行出错时，函数照旧执行下面的 PowerShell 代码。
$script:BP_GuardExeCache = @{}
function Get-BPGuardExe([int]$Minor = 3) {
    if ($env:CG_NO_NATIVE) { return '' }
    $exe = Join-Path $script:BP_GuardRoot 'bin\cg-guard.exe'
    if (-not $script:BP_GuardExeCache.ContainsKey('v')) {
        $v = @(0, 0)
        if ([IO.File]::Exists($exe)) { try { $o = (& $exe version 2>$null | Out-String); if ($o -match 'cg-guard (\d+)\.(\d+)') { $v = @([int]$Matches[1], [int]$Matches[2]) } } catch {} }
        $script:BP_GuardExeCache['v'] = $v
    }
    $v = $script:BP_GuardExeCache['v']
    if ($v[0] -gt 7 -or ($v[0] -eq 7 -and $v[1] -ge $Minor)) { return $exe }
    return ''
}

function Invoke-BPGuardJson([string[]]$Arguments) {
    # 运行 cg-guard 并读取最后一行 JSON；没法用 / 没有有效输出时返回 $null（调用方改用 PowerShell 版）
    $exe = Get-BPGuardExe 3
    if (-not $exe) { return $null }
    try {
        $out = @(& $exe @Arguments --json 2>$null)
        $line = @($out | Where-Object { ([string]$_).TrimStart().StartsWith('{') }) | Select-Object -Last 1
        if (-not $line) { return $null }
        return ($line | ConvertFrom-Json)
    } catch { return $null }
}

# ------------------------------------------------------------------ profiles.yaml（Clash Verge 固定格式，按行解析）
function Get-BPProfiles([string]$DataDir) {
    $path = Join-Path $DataDir 'profiles.yaml'
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($l in ((Read-BPText $path) -split "`r?`n")) { $lines.Add($l) }
    $current = ''; $items = @(); $inItems = $false; $cur = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match '^current:\s*(\S*)') { $current = $Matches[1]; $inItems = $false; continue }
        if ($l -match '^items:') { $inItems = $true; continue }
        if ($l -match '^\S' -and $l -notmatch '^- ') { $inItems = $false; if ($cur) { $cur.End = $i - 1; $items += $cur; $cur = $null }; continue }
        if (-not $inItems) { continue }
        if ($l -match '^- uid:\s*(\S+)') {
            if ($cur) { $cur.End = $i - 1; $items += $cur }
            $cur = [pscustomobject]@{ Uid = $Matches[1]; Start = $i; End = $i; Type = ''; Url = ''; File = ''; Script = $null; OptionIdx = -1; ScriptIdx = -1 }
            continue
        }
        if (-not $cur) { continue }
        if ($l -match '^  type:\s*(\S+)')  { $cur.Type = $Matches[1] }
        elseif ($l -match '^  url:\s*(\S+)') { $cur.Url = $Matches[1] }
        elseif ($l -match '^  file:\s*(\S+)') { $cur.File = $Matches[1] }
        elseif ($l -match '^  option:\s*$') { $cur.OptionIdx = $i }
        elseif ($l -match '^    script:\s*(\S*)' -and $cur.OptionIdx -ge 0) { $cur.Script = $Matches[1]; $cur.ScriptIdx = $i }
    }
    if ($cur) { $cur.End = $lines.Count - 1; while ($cur.End -gt $cur.Start -and -not $lines[$cur.End].Trim()) { $cur.End-- }; $items += $cur }
    return [pscustomobject]@{ Path = $path; Lines = $lines; Current = $current; Items = $items }
}

function Get-BPBaiyangItem($P) {
    $cands = @($P.Items | Where-Object { $_.Type -eq 'remote' -and $_.Url -match '/baiyang/api/' })
    if ($cands.Count -eq 0) { return $null }
    $c = @($cands | Where-Object { $_.Uid -eq $P.Current })
    if ($c.Count -gt 0) { return $c[0] }
    return $cands[-1]
}

function Get-BPConfigMode {
    # 返回 strict / original / unknown（控制台显示用，只读）
    try {
        $d = Get-BPDataDir
        $p = Get-BPProfiles $d
        $b = Get-BPBaiyangItem $p
        if (-not $b) { return 'unknown' }
        if ($p.Current -eq $b.Uid -and $b.Script -eq $script:BP_StrictUid -and (Test-Path -LiteralPath (Join-Path $d "profiles\$($script:BP_StrictUid).js"))) { return 'strict' }
        return 'original'
    } catch { return 'unknown' }
}

function Test-BPStrict([string]$DataDir) {
    $p = Get-BPProfiles $DataDir
    $b = Get-BPBaiyangItem $p
    if (-not $b) { return $false }
    if ($p.Current -ne $b.Uid -or $b.Script -ne $script:BP_StrictUid) { return $false }
    if (-not @($p.Items | Where-Object { $_.Uid -eq $script:BP_StrictUid -and $_.Type -eq 'script' })) { return $false }
    $js = Join-Path $DataDir "profiles\$($script:BP_StrictUid).js"
    $want = Get-BPRenderedJs
    if (-not (Test-Path -LiteralPath $js) -or -not $want) { return $false }
    if ([IO.File]::ReadAllText($js, [Text.Encoding]::UTF8) -ne $want) { return $false }
    $v = Read-BPText (Join-Path $DataDir 'verge.yaml')
    if ($v -notmatch '(?m)^enable_tun_mode:\s*true' -or $v -match '(?m)^enable_system_proxy:\s*true') { return $false }
    $c = Read-BPText (Join-Path $DataDir 'config.yaml')
    if ($c -notmatch '(?m)^mode:\s*rule' -or $c -notmatch '(?m)^ipv6:\s*false') { return $false }
    return $true
}

function Set-BPItemScript($P, $Item, [string]$Value) {
    # 修改（或插入）某个订阅条目的 option.script
    $lines = $P.Lines
    if ($Item.ScriptIdx -ge 0) { $lines[$Item.ScriptIdx] = "    script: $Value"; return }
    if ($Item.OptionIdx -ge 0) { $lines.Insert($Item.OptionIdx + 1, "    script: $Value"); return }
    $lines.Insert($Item.End + 1, "    script: $Value")
    $lines.Insert($Item.End + 1, '  option:')
}

function Save-BPOriginal([string]$DataDir) {
    # 保存“白羊原始配置”快照（只在当前不是严格配置时调用）
    $tmp = "$($script:BP_SnapDir).new"
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    New-Item -ItemType Directory -Path (Join-Path $tmp 'profiles') -Force | Out-Null
    foreach ($f in @('config.yaml', 'verge.yaml', 'profiles.yaml')) {
        $src = Join-Path $DataDir $f
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $tmp $f) -Force }
    }
    Get-ChildItem -LiteralPath (Join-Path $DataDir 'profiles') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '\.bak' } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $tmp "profiles\$($_.Name)") -Force }
    [IO.File]::WriteAllText((Join-Path $tmp 'meta.json'), ([ordered]@{ ts = (Get-Date).ToString('o'); source = $DataDir } | ConvertTo-Json), $script:BP_Utf8)
    $prev = "$($script:BP_SnapDir).prev"
    if (Test-Path -LiteralPath $prev) { Remove-Item -LiteralPath $prev -Recurse -Force }
    if (Test-Path -LiteralPath $script:BP_SnapDir) { Rename-Item -LiteralPath $script:BP_SnapDir -NewName (Split-Path $prev -Leaf) }
    Rename-Item -LiteralPath $tmp -NewName (Split-Path $script:BP_SnapDir -Leaf)
}

function Set-BPStrict([string]$DataDir) {
    $pin = Get-BPPinnedNode
    $js = Get-BPRenderedJs $pin
    if (-not $js) { throw '找不到严格规则脚本模板（strict-profile.js）' }
    $p = Get-BPProfiles $DataDir
    $b = Get-BPBaiyangItem $p
    if (-not $b) { throw 'Clash Verge 里没有白羊订阅（请先在白羊加速或 Clash Verge 里导入一次订阅）' }
    $sub = Read-BPText (Join-Path $DataDir "profiles\$($b.File)")
    if ($sub -and -not (Find-BPNode $sub $pin)) { throw ('白羊订阅里没有锁定的节点「{0}」' -f $pin.name) }

    Write-BPText (Join-Path $DataDir "profiles\$($script:BP_StrictUid).js") $js

    # profiles.yaml：当前订阅 = 白羊；白羊订阅挂上严格脚本；脚本条目缺失则补上
    Set-BPItemScript $p $b $script:BP_StrictUid
    $lines = $p.Lines
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^current:') { $lines[$i] = "current: $($b.Uid)"; break } }
    $text = ($lines -join "`n")
    if ($text -notmatch "(?m)^- uid:\s*$([regex]::Escape($script:BP_StrictUid))\s*$") {
        $epoch = [int][double]::Parse((Get-Date -UFormat %s))
        $text = $text.TrimEnd() + "`n- uid: $($script:BP_StrictUid)`n  type: script`n  name: null`n  file: $($script:BP_StrictUid).js`n  updated: $epoch`n"
    }
    $text = [regex]::Replace($text, '(?m)^(\s+update_interval:\s*)\d+', '${1}30')
    Write-BPText $p.Path $text

    $cfg = Join-Path $DataDir 'config.yaml'
    $t = Read-BPText $cfg
    foreach ($kv in @(
        @('(?m)^mode:\s*\S+', 'mode: rule'), @('(?m)^ipv6:\s*\S+', 'ipv6: false'), @('(?m)^allow-lan:\s*\S+', 'allow-lan: false'),
        @('(?m)^log-level:\s*\S+', 'log-level: warning'), @('(?m)^(\s+mtu:\s*)\d+', '${1}1360'), @('(?m)^(\s+stack:\s*)\S+', '${1}mixed'),
        @('(?m)^(\s+strict-route:\s*)\S+', '${1}true'), @('(?m)^(\s+route-exclude-address:\s*).*$', '${1}[]'))) { $t = [regex]::Replace($t, $kv[0], $kv[1]) }
    Write-BPText $cfg $t

    $vp = Join-Path $DataDir 'verge.yaml'
    $t = Read-BPText $vp
    foreach ($kv in @(
        @('(?m)^enable_tun_mode:\s*\S+', 'enable_tun_mode: true'), @('(?m)^enable_system_proxy:\s*\S+', 'enable_system_proxy: false'),
        @('(?m)^startup_script:.*$', 'startup_script: null'), @('(?m)^auto_check_update: true$', 'auto_check_update: false'),
        @('(?m)^enable_auto_delay_detection:.*$', 'enable_auto_delay_detection: false'), @('(?m)^  ip: true$', '  ip: false'), @('(?m)^  test: true$', '  test: false'))) { $t = [regex]::Replace($t, $kv[0], $kv[1]) }
    Write-BPText $vp $t
}

function Restore-BPOriginal([string]$DataDir) {
    # 还原白羊原始配置；返回说明文字
    $how = ''
    if (Test-Path -LiteralPath (Join-Path $script:BP_SnapDir 'profiles.yaml')) {
        foreach ($f in @('config.yaml', 'verge.yaml', 'profiles.yaml')) {
            $src = Join-Path $script:BP_SnapDir $f
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $DataDir $f) -Force }
        }
        # 订阅文件保留当前（更新），其余辅助文件按快照还原
        $snapP = Get-BPProfiles $script:BP_SnapDir
        $remoteFiles = @($snapP.Items | Where-Object { $_.Type -eq 'remote' } | ForEach-Object { $_.File })
        Get-ChildItem -LiteralPath (Join-Path $script:BP_SnapDir 'profiles') -File -ErrorAction SilentlyContinue |
            Where-Object { $remoteFiles -notcontains $_.Name -and $_.Name -ne "$($script:BP_StrictUid).js" } |
            ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $DataDir "profiles\$($_.Name)") -Force }
        $ts = ''; try { $ts = ([datetime](Get-Content -LiteralPath (Join-Path $script:BP_SnapDir 'meta.json') -Raw | ConvertFrom-Json).ts).ToString('MM-dd HH:mm') } catch {}
        $how = "已恢复白羊原始配置（快照 $ts）"
    } else {
        $how = '已恢复白羊原始配置（全部节点 + 官方规则）'
    }
    # 无论快照里是什么，白羊订阅都不能再挂严格脚本，否则“原始配置”仍是只有韩国节点
    $p = Get-BPProfiles $DataDir
    $changed = $false
    foreach ($it in @($p.Items | Where-Object { $_.Script -eq $script:BP_StrictUid -and $_.ScriptIdx -ge 0 })) { $p.Lines[$it.ScriptIdx] = '    script: null'; $changed = $true }
    if ($changed) { Write-BPText $p.Path ($p.Lines -join "`n") }
    return $how
}

# ------------------------------------------------------------------ 订阅
function Get-BPNodeLine([string]$Text, $Pin = $null) {
    # 锁定节点在订阅里的那一行（flow 写法）；用于概览显示协议等细节
    $n = Find-BPNode $Text $Pin
    if (-not $n) { return '' }
    foreach ($l in ($Text -split "`r?`n")) {
        if ($l -match '^\s*-\s*\{' -and $l.Contains($n.name) -and $l -match ('server:\s*' + [regex]::Escape($n.server))) { return $l.Trim() }
    }
    return ('name: {0}, type: {1}, server: {2}, port: {3}' -f $n.name, $n.type, $n.server, $n.port)
}

function Get-BPNodeEndpoint($Node) {
    if (-not $Node) { return ':' }
    return ('{0}:{1}' -f $Node.server, $Node.port)
}

function Invoke-BPFetchSub([string]$Url) {
    # 按订阅地址拉取白羊订阅（当前域名失败时依次尝试官方镜像发现地址和已知域名）
    # 返回 content / host / userinfo（subscription-userinfo 头：流量与到期）；失败时 content 为空、error 有说明
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $out = [ordered]@{ content = ''; host = ''; userinfo = ''; error = '' }
    $m = [regex]::Match([string]$Url, '^https?://([^/]+)/baiyang/api/([^?\s]+)')
    if (-not $m.Success) { $out.error = '白羊订阅地址格式无法识别'; return [pscustomobject]$out }
    $curHost = $m.Groups[1].Value; $token = $m.Groups[2].Value
    $hosts = @($curHost)
    try {
        $o = Invoke-WebRequest -Uri $script:BP_OssUrl -UseBasicParsing -TimeoutSec 8
        $hosts += @(([string]$o.Content) -split "`r?`n" | ForEach-Object { ($_ -replace '^https?://', '').Trim().TrimEnd('/') } | Where-Object { $_ -match '^[A-Za-z0-9.-]+$' })
    } catch {}
    $hosts = @($hosts + $script:BP_SubHosts | Select-Object -Unique)
    foreach ($h in $hosts) {
        try {
            $r = Invoke-WebRequest -Uri ("https://{0}/baiyang/api/{1}?flag=meta" -f $h, $token) -UseBasicParsing -TimeoutSec 25 -Headers @{ 'User-Agent' = 'clash-verge/v2.4.2' }
            $t = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
            if ($r.StatusCode -eq 200 -and $t.Length -gt 500 -and $t -match '(?m)^proxies:' -and @(Get-BPNodeList $t).Count -gt 0) {
                $out.content = $t; $out.host = $h
                try { $out.userinfo = [string]$r.Headers['subscription-userinfo'] } catch {}
                break
            }
        } catch {}
    }
    if (-not $out.content) { $out.error = '订阅拉取失败（所有订阅地址都连不上，或返回内容里没有可用节点）' }
    return [pscustomobject]$out
}

function Update-BPSubscription([string]$DataDir) {
    # 拉取最新白羊订阅；返回 ok / changed（订阅内容变了）/ nodeChanged（韩国节点地址或端口变了）/ message
    # Rust 版只处理默认数据目录；它拉取失败时不再用 PowerShell 重拉一遍（同样的网络，结果相同，只会让等待时间翻倍）
    if ($DataDir -and ((Get-BPDataDir) -eq $DataDir)) {
        $r = Invoke-BPGuardJson @('sub-update', '--verge')
        if ($r -and ($r.ok -or [string]$r.message -notmatch 'TLS')) { return $r }
    }
    return (Update-BPSubscriptionPS $DataDir)
}

function Update-BPSubscriptionPS([string]$DataDir) {
    $res =[ordered]@{ ok = $false; changed = $false; nodeChanged = $false; pinMissing = $false; host = ''; message = '' }
    $p = Get-BPProfiles $DataDir
    $b = Get-BPBaiyangItem $p
    if (-not $b) { $res.message = '没有找到白羊订阅'; return [pscustomobject]$res }
    $curHost = ([regex]::Match($b.Url, '^https?://([^/]+)')).Groups[1].Value
    $f = Invoke-BPFetchSub $b.Url
    if (-not $f.content) { $res.message = $f.error; return [pscustomobject]$res }
    $content = $f.content; $res.host = $f.host

    $pin = Get-BPPinnedNode
    $file = Join-Path $DataDir "profiles\$($b.File)"
    $old = Read-BPText $file
    $newNode = Find-BPNode $content $pin
    $oldEp = Get-BPNodeEndpoint (Find-BPNode $old $pin)
    $newEp = Get-BPNodeEndpoint $newNode
    $res.ok = $true
    $res.pinMissing = (-not $newNode)
    $res.changed = ($content -ne $old)
    $res.nodeChanged = ($oldEp -ne $newEp)
    if ($res.changed) { Write-BPText $file $content }
    if ($res.host -ne $curHost) {
        # 订阅域名换了：写回 profiles.yaml，之后 Clash Verge 自己更新也用新地址
        $p2 = Get-BPProfiles $DataDir
        $b2 = @($p2.Items | Where-Object { $_.Uid -eq $b.Uid })[0]
        for ($i = $b2.Start; $i -le $b2.End; $i++) { if ($p2.Lines[$i] -match '^  url:') { $p2.Lines[$i] = '  url: ' + ($b.Url -replace '^(https?://)[^/]+', ('${1}' + $res.host)); break } }
        Write-BPText $p2.Path ($p2.Lines -join "`n")
    }
    $portOld = ($oldEp -split ':')[-1]; $portNew = ($newEp -split ':')[-1]
    if ($res.pinMissing) { $res.message = ('订阅已更新，但里面已经没有锁定的节点「{0}」，请在「配置与订阅」里改锁其他节点' -f $pin.name) }
    elseif ($res.nodeChanged) { $res.message = "锁定节点入口已变化（端口 $portOld → $portNew），已写入新订阅" }
    elseif ($res.changed) { $res.message = "订阅已更新，锁定节点入口未变（端口 $portNew）" }
    else { $res.message = "订阅已是最新，锁定节点入口未变（端口 $portNew）" }
    return [pscustomobject]$res
}

# ------------------------------------------------------------------ Clash Verge 进程
function Get-BPVergeExe {
    $p = Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
    if ($p) { return $p.Path }
    try {
        $c = Get-Content -LiteralPath (Join-Path $script:BP_GuardRoot 'guard.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($r in @(@($c.vergeCoreRoots) + @($c.coreRoots) | Where-Object { $_ })) { $x = Join-Path $r 'clash-verge.exe'; if (Test-Path -LiteralPath $x) { return $x } }
    } catch {}
    foreach ($d in @('D:\Program Files\uu\Clash Verge', "$env:ProgramFiles\Clash Verge")) { $x = Join-Path $d 'clash-verge.exe'; if (Test-Path -LiteralPath $x) { return $x } }
    return $null
}

function Restart-BPClash {
    # 重启 Clash Verge 让新配置生效（界面重启后，服务会用新生成的配置重启内核）
    $exe = Get-BPVergeExe
    if (-not $exe) { return $false }
    Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Get-Process -Name 'verge-mihomo', 'verge-mihomo-alpha' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $exe)
    return $true
}

function Test-BPRuntimePinned([string]$DataDir) {
    $t = Read-BPText (Join-Path $DataDir 'clash-verge.yaml')
    $section = ''; $n = 0
    foreach ($l in ($t -split "`r?`n")) {
        if ($l -match '^([A-Za-z0-9_-]+):') { $section = $Matches[1] }
        if ($section -eq 'proxies' -and $l -match '^\s*-\s+name:') { $n++ }
    }
    return ($n -eq 1 -and $t.Contains('MATCH,KR-ONLY') -and $t -notmatch 'type:\s*url-test')
}

# ------------------------------------------------------------------ 结束所有 Claude 程序
function Get-BPClaudeProcesses {
    $self = $PID
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessId -ne $self -and (
            $_.Name -match '^claude(\.exe)?$' -or
            ($_.Name -match '^(node|bun)(\.exe)?$' -and [string]$_.CommandLine -match '@anthropic-ai[\\/]claude-code|claude-code[\\/]cli')
        )
    })
}

function Stop-BPClaudeProcesses {
    $found = @(Get-BPClaudeProcesses)
    foreach ($p in $found) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {} }
    Start-Sleep -Milliseconds 1500
    $left = @(Get-BPClaudeProcesses)
    foreach ($p in $left) { try { & taskkill.exe /F /T /PID $p.ProcessId 2>&1 | Out-Null } catch {} }
    Start-Sleep -Milliseconds 800
    $left = @(Get-BPClaudeProcesses)
    return [pscustomobject]@{ Found = $found.Count; Left = $left.Count }
}
