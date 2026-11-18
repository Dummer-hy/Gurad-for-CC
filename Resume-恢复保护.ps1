<#
  开启保护（两种引擎）：
  ■ 内置引擎（v8 起，推荐）：Claude保护 自带 mihomo 内核，与电脑上的 Clash Verge / 白羊 App 完全分开
    1. 关掉会冲突的 Clash Verge / 白羊 App（只结束进程，不改它们的配置）
    2. 拉取最新白羊订阅（或使用导入的本地配置）→ 按锁定节点生成运行配置（只含这一个节点 + 固定规则）并校验
    3. 启动内置内核（TUN 或系统代理），确认运行配置只有锁定的节点
    4. 启用严格模式（防火墙默认拒绝 + 看门狗）
  ■ Clash Verge 引擎（旧）：
    1. 退出白羊官方 App（它和 Clash Verge 共用配置目录，会覆盖配置）
    2. [-ConfigMode Strict，默认] 拉取最新白羊订阅 → 若当前不是严格配置：先保存「白羊原始配置」快照，再套用严格配置
    3. 启动/重启 Clash Verge(TUN)，确认运行配置只剩锁定的节点
    4. 启用严格模式（防火墙默认拒绝 + 看门狗）
  原本没开保护时，失败会回到原来的普通网络；保护已开着时（例如切换节点）失败则保持断网，不会回落直连。
  -ConfigMode Keep：不改 Clash Verge 配置（仅旧引擎）
  -NodeB64：要锁定的节点名称（UTF-8 + Base64，避免命令行引号/emoji 问题）；保护已开启时用它切换节点
  -Engine Builtin|Verge：切换引擎；-NetMode Tun|SysProxy：内置引擎的接管方式；-Source Baiyang|Local：节点来源
#>
param([switch]$NoPause, [ValidateSet('Strict', 'Keep')][string]$ConfigMode = 'Strict', [string]$NodeB64 = '',
      [ValidateSet('', 'Builtin', 'Verge')][string]$Engine = '', [ValidateSet('', 'Tun', 'SysProxy')][string]$NetMode = '',
      [ValidateSet('', 'Baiyang', 'Local')][string]$Source = '')
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $a = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigMode {1}' -f $PSCommandPath, $ConfigMode
    if ($NoPause) { $a += ' -NoPause' }
    if ($NodeB64) { $a += ' -NodeB64 ' + $NodeB64 }
    if ($Engine)  { $a += ' -Engine ' + $Engine }
    if ($NetMode) { $a += ' -NetMode ' + $NetMode }
    if ($Source)  { $a += ' -Source ' + $Source }
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
function Done([int]$code, [string]$msg = '') { Write-ToggleResult 'on' ($code -eq 0) $msg; if (-not $NoPause) { Read-Host '按回车键关闭' | Out-Null }; exit $code }

Write-Host '==== 开启保护 ====' -ForegroundColor Yellow
$root  = 'C:\ProgramData\ClaudeGuard'
$guard = Join-Path $root 'bin\ClaudeGuard.ps1'
if (-not (Test-Path -LiteralPath $guard)) { $guard = Join-Path $PSScriptRoot 'Config_Template\scripts\ClaudeGuard.ps1' }
if (-not (Test-Path -LiteralPath $guard)) { Write-Host '未找到 ClaudeGuard.ps1，请先运行「Claude保护-一键升级」。' -ForegroundColor Red; Done 1 '未找到 ClaudeGuard.ps1，请先运行「Claude保护-一键升级」。' }

# 白羊 App 与 Clash Verge 共用配置目录，不能并行
Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -like '*\白羊加速\*' } | Stop-Process -Force -ErrorAction SilentlyContinue

# 优先保障 Claude 网络状况：清理后台抢占中继 28000 端口高并发的常驻进程（如 douyin_guard 等）
foreach ($h in @('douyin_guard', 'douyin')) {
    Get-Process -Name $h -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "      [QoS] 正在清理抢网后台进程: $($_.Name) (释放住宅节点并发队列)..." -ForegroundColor Yellow
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
}

# 同步最新的守护脚本与模块到 ProgramData（从套件目录运行时）
foreach ($n in @('ClaudeGuard.ps1', 'BaiyangProfile.ps1', 'BuiltinCore.ps1', 'cg-guard.exe')) {
    $local = Join-Path $PSScriptRoot "Config_Template\scripts\$n"
    if (Test-Path -LiteralPath $local) { try { Copy-Item -LiteralPath $local -Destination (Join-Path $root "bin\$n") -Force -ErrorAction SilentlyContinue } catch {} }
}

# 10.6 起：整个开启流程由 cg-guard.exe 完成，下面的 PowerShell 流程只在没有新版 cg-guard、
# 或它自身意外出错（返回 70）时使用。cg-guard 改用本脚本时会设置 CG_NO_NATIVE，避免来回调用。
$cgExe = Join-Path $root 'bin\cg-guard.exe'
if (-not $env:CG_NO_NATIVE -and (Test-Path -LiteralPath $cgExe)) {
    $cgv = ''; try { $cgv = (& $cgExe version 2>$null | Out-String) } catch {}
    if ($cgv -match 'cg-guard (\d+)\.(\d+)' -and (([int]$Matches[1] -gt 7) -or ([int]$Matches[1] -eq 7 -and [int]$Matches[2] -ge 4))) {
        $ca = @('on', '--config', $ConfigMode)
        if ($NodeB64) { $ca += @('--node-b64', $NodeB64) }
        if ($Engine)  { $ca += @('--engine', $Engine) }
        if ($NetMode) { $ca += @('--net-mode', $NetMode) }
        if ($Source)  { $ca += @('--source', $Source) }
        & $cgExe @ca | Out-Host
        $cgCode = $LASTEXITCODE
        if ($cgCode -ne 70) { if (-not $NoPause) { Read-Host '按回车键关闭' | Out-Null }; exit $cgCode }
        Write-Host 'cg-guard 意外出错，改用 PowerShell 流程' -ForegroundColor Yellow
    }
}

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
function Test-TunUp { $a = Get-NetAdapter -Name 'Mihomo' -ErrorAction SilentlyContinue; return ($a -and $a.Status -eq 'Up') }
function Find-Module([string]$name) {
    foreach ($c in @((Join-Path $PSScriptRoot $name), (Join-Path $root "bin\$name"), (Join-Path $PSScriptRoot "Config_Template\scripts\$name"))) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}
function Test-FirewallLocked {
    # 保护是否已经开着（三个配置文件的出站默认动作都是 Block）
    try { return (@(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { $_.DefaultOutboundAction -ne 'Block' }).Count -eq 0) } catch { return $false }
}

# ---------------------------------------------------------------- 选择引擎
$bcLoaded = $false
$bpMod = Find-Module 'BaiyangProfile.ps1'; $bcMod = Find-Module 'BuiltinCore.ps1'
if ($bpMod -and $bcMod) { try { . $bpMod; . $bcMod; $bcLoaded = $true } catch { Write-Host ('[引擎] 内置引擎模块加载失败：' + $_.Exception.Message) -ForegroundColor Yellow } }
$curEngine = $(if ($bcLoaded) { Get-BCEngine } else { 'verge' })
$useEngine = $(if ($Engine) { $Engine.ToLower() } else { $curEngine })
if ($useEngine -eq 'builtin' -and -not $bcLoaded) { Done 1 '缺少内置引擎模块（BuiltinCore.ps1），请在「维护」里更新到最新版。' }
$wasLocked = Test-FirewallLocked

if ($useEngine -eq 'builtin') {
    Write-Host '[引擎] 内置引擎（Claude保护 自带内核）' -ForegroundColor Cyan
    function Fail([string]$msg) {
        Write-Host $msg -ForegroundColor Red
        if ($wasLocked) {
            # 保护原本开着：保持防火墙默认拒绝（断网而不是直连），重新拉起守护以显示真实状态
            try { Start-ScheduledTask -TaskName 'ClaudeGuard' -ErrorAction SilentlyContinue } catch {}
            Done 1 ($msg + ' 保护仍开着，网络暂时断开（不会回落直连）；可以再试一次，或关闭保护。')
        }
        try { [void](Stop-BCCore -Disable) } catch {}
        Done 1 ($msg + ' 网络保持原来的状态。')
    }

    # 2. 内核文件、目录、订阅
    try { Write-Host ('[内核] ' + (Install-BCCoreExe)) } catch { Fail ('安装内置内核失败：' + $_.Exception.Message) }
    [void](Initialize-BCSub)
    # 内置引擎不再借用 Clash Verge：它的配置如果还是旧引擎套的严格配置，还原成白羊原始配置（以后单独打开 Clash Verge / 白羊 App 就是原样）
    try { if ((Get-BPConfigMode) -eq 'strict') { Write-Host ('[配置] Clash Verge：' + (Restore-BPOriginal (Get-BPDataDir))) } } catch { Write-Host ('[配置] 还原 Clash Verge 配置失败（不影响内置引擎）：' + $_.Exception.Message) -ForegroundColor Yellow }
    $S = Get-BCSettings
    $S.engine = 'builtin'
    if ($NetMode) { $S.netMode = $(if ($NetMode -eq 'SysProxy') { 'sysproxy' } else { 'tun' }) }
    if ($Source)  { $S.subSource = $Source.ToLower() }
    if ($S.subSource -eq 'local' -and -not (Test-Path -LiteralPath (Get-BCSubFile 'local'))) { Fail '没有导入过本地配置，请先在「配置与订阅」里导入。' }
    if ($S.subSource -eq 'baiyang') {
        Write-Host '[订阅] 拉取最新白羊订阅…'
        $u = Update-BCSubscription
        if ($u.ok) { Write-Host ('      ' + $u.message) -ForegroundColor Green } else { Write-Host ('      [注意] ' + $u.message + '，继续使用本地已有的订阅') -ForegroundColor Yellow }
    }
    $subText = Get-BCSubText $S.subSource
    if (-not $subText) { Fail '还没有可用的订阅（白羊订阅拉取失败，本地也没有缓存）。' }

    # 3. 锁定节点
    if ($NodeB64) {
        $want = ''
        try { $want = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($NodeB64)) } catch {}
        $node = $(if ($want) { Find-BPNode $subText ([pscustomobject]@{ name = $want; fuzzy = @() }) } else { $null })
        if (-not $node) { Fail ("订阅里找不到节点「{0}」，请先更新订阅后重新选择。" -f $want) }
        if (-not $node.country) { Fail ("无法识别节点「{0}」所在的国家/地区，不能锁定（守护需要知道期望的出口国家）。" -f $want) }
        Set-BPPinnedNode $node.name $node.country
        Write-Host ("[节点] 锁定节点：{0}（期望出口 {1}）" -f $node.name, $node.country) -ForegroundColor Green
    }
    $pin = Get-BPPinnedNode
    if (-not (Find-BPNode $subText $pin)) { Fail ("当前节点来源里没有锁定的节点「{0}」，请在「配置与订阅」里重新选择节点。" -f $pin.name) }
    Save-BCSettings $S
    $S = Get-BCSettings

    # 4. 守护配置跟随（期望国家 + 引擎）；守护只在启动时读配置，先停下（防火墙状态保持不变）
    try { if (Set-BPGuardCountry $pin.country) { Write-Host ("[节点] 守护期望出口已改为 {0}" -f $pin.country) -ForegroundColor Green } } catch {}
    try { if (Set-BCGuardEngine 'builtin' $S.netMode) { Write-Host '[引擎] 守护已切换到内置引擎' -ForegroundColor Green } } catch { Fail ('更新守护配置失败：' + $_.Exception.Message) }
    try { $t = Get-ScheduledTask -TaskName 'ClaudeGuard' -ErrorAction Stop; if ($t.State -eq 'Running') { Stop-ScheduledTask -TaskName 'ClaudeGuard' } } catch {}

    # 5. 生成并校验运行配置，(重)启内核
    $r = Update-BCRuntime -NoReload
    if (-not $r.ok) { Fail ('生成运行配置失败：' + $r.message) }
    if ($r.missing) { Fail '运行配置里没有锁定的节点。' }
    Write-Host ('[配置] ' + $r.message) -ForegroundColor Green
    # 冲突软件（放在拉完订阅、生成好配置之后：保护开着时旧内核还能帮忙拉订阅）：Clash Verge 界面/内核、白羊 App（只结束进程，不改它们的配置）
    $conf = @(Get-BCConflicts | Where-Object { $_.kind -eq 'process' })
    if ($conf.Count -gt 0) {
        Write-Host ('[冲突] 关闭：' + (($conf | ForEach-Object { $_.name } | Select-Object -Unique) -join '、'))
        $left = Stop-BCConflicts
        if ($left -gt 0) { Write-Host "[冲突] 仍有 $left 个进程无法结束（已被防火墙隔离，不影响安全）" -ForegroundColor Yellow }
    }

    $modeTxt = $(if ($S.netMode -eq 'sysproxy') { '系统代理' } else { 'TUN' })
    $need = $r.changed -or (@(Get-BCCoreProcess).Count -eq 0)
    if ($need) {
        Write-Host ("[内核] 启动内置内核（{0}）…" -f $modeTxt)
        [void](Stop-BCCore)
        try { Register-BCTask; [void](Start-BCCore) } catch { Fail ('启动内置内核失败：' + $_.Exception.Message) }
    } else { Write-Host '[内核] 内置内核已在运行，配置无变化' }
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 2
        if (@(Get-BCCoreProcess).Count -eq 0) { continue }
        if (-not (Test-BCApi)) { continue }
        if ($S.netMode -ne 'sysproxy') { $ti = Get-BCTunInfo; if (-not $ti.up -or -not $ti.addr.StartsWith('198.19.0.')) { continue } }
        $ready = $true; break
    }
    if (-not $ready) {
        $tail = ''; try { $tail = ((Get-Content -LiteralPath $script:BC_LogFile -Tail 3 -Encoding UTF8) -join ' ') } catch {}
        Fail ("内置内核没能在 60 秒内就绪（{0}）。{1}" -f $modeTxt, $tail)
    }
    try {
        $px = Invoke-BCApi 'GET' '/proxies'
        $real = @($px.proxies.PSObject.Properties | Where-Object { $_.Value.type -notin @('Direct', 'Reject', 'RejectDrop', 'Pass', 'PassRule', 'Compatible', 'Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Relay') })
        if ($real.Count -ne 1 -or $real[0].Name -ne (Find-BPNode $subText $pin).name) { Fail ('内置内核的运行配置不是只有锁定的节点（实际：{0}）。' -f (($real | ForEach-Object { $_.Name }) -join '、')) }
    } catch { Fail ('无法读取内置内核状态：' + $_.Exception.Message) }
    Write-Host ("[内核] 就绪：只有锁定的节点 · {0}" -f $modeTxt) -ForegroundColor Green
    Start-Sleep -Seconds 2

    $rc = Invoke-GuardOp 'Resume'
    if ($rc -eq 0) {
        Write-Host ''; Write-Host '保护已开启：防火墙默认拒绝 + 看门狗已启动。现在可以放心使用 Claude。' -ForegroundColor Green
        Done 0 ('保护已开启 · 内置引擎（{0}）· 锁定节点：{1}' -f $modeTxt, $pin.name)
    }
    Write-Host ''; Write-Host '开启失败，已自动回滚到正常上网状态（见上方输出）。' -ForegroundColor Red
    Done 1 '开启失败，已自动回滚到普通网络。常见原因：节点暂时不通，请稍后再试；详情见日志。'
}

# ---------------------------------------------------------------- Clash Verge 引擎（旧）
if ($bcLoaded -and ($curEngine -eq 'builtin' -or $Engine)) {
    # 从内置引擎切回：先停掉内置内核，守护配置改回 Clash Verge
    Write-Host '[引擎] 切换到 Clash Verge 引擎' -ForegroundColor Cyan
    try { [void](Stop-BCCore -Disable) } catch {}
    try { $S = Get-BCSettings; $S.engine = 'verge'; Save-BCSettings $S } catch {}
    try { [void](Set-BCGuardEngine 'verge') } catch { Write-Host ('[引擎] 更新守护配置失败：' + $_.Exception.Message) -ForegroundColor Yellow }
    try { $t = Get-ScheduledTask -TaskName 'ClaudeGuard' -ErrorAction Stop; if ($t.State -eq 'Running') { Stop-ScheduledTask -TaskName 'ClaudeGuard' } } catch {}
}

# ---------------------------------------------------------------- 配置：订阅 + 严格配置
$strict = ($ConfigMode -eq 'Strict')
$needRestart = $false
$dataDir = $null
if ($strict) {
    $mod = $null
    foreach ($c in @((Join-Path $PSScriptRoot 'BaiyangProfile.ps1'), (Join-Path $root 'bin\BaiyangProfile.ps1'), (Join-Path $PSScriptRoot 'Config_Template\scripts\BaiyangProfile.ps1'))) { if (Test-Path -LiteralPath $c) { $mod = $c; break } }
    if (-not $mod) { Write-Host '缺少 BaiyangProfile.ps1，请重新运行「Claude保护-一键升级」。' -ForegroundColor Red; Done 1 '缺少配置切换模块，请重新运行「Claude保护-一键升级」。' }
    . $mod
    $dataDir = Get-BPDataDir

    Write-Host '[配置] 拉取最新白羊订阅…'
    $u = Update-BPSubscription $dataDir
    if ($u.ok) { Write-Host ('      ' + $u.message) -ForegroundColor Green; if ($u.nodeChanged) { $needRestart = $true } }
    else { Write-Host ('      [注意] ' + $u.message + '，继续使用本地订阅') -ForegroundColor Yellow }

    # 锁定节点：校验所选节点在订阅里、能识别出国家，然后写入锁定记录
    if ($NodeB64) {
        $want = ''
        try { $want = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($NodeB64)) } catch {}
        $bItem = Get-BPBaiyangItem (Get-BPProfiles $dataDir)
        $subText = $(if ($bItem) { Read-BPText (Join-Path $dataDir "profiles\$($bItem.File)") } else { '' })
        $node = $(if ($want) { Find-BPNode $subText ([pscustomobject]@{ name = $want; fuzzy = @() }) } else { $null })
        if (-not $node) { Write-Host "订阅里找不到节点「$want」" -ForegroundColor Red; Done 1 ("订阅里找不到节点「{0}」，请先更新订阅后重新选择。" -f $want) }
        if (-not $node.country) { Done 1 ("无法识别节点「{0}」所在的国家/地区，不能锁定（守护需要知道期望的出口国家）。" -f $want) }
        Set-BPPinnedNode $node.name $node.country
        Write-Host ("[节点] 锁定节点：{0}（期望出口 {1}）" -f $node.name, $node.country) -ForegroundColor Green
    }
    $pin = Get-BPPinnedNode
    # 守护的期望出口国家跟随锁定节点；守护只在启动时读配置，需要重启它
    $guardCfgChanged = $false
    try { $guardCfgChanged = Set-BPGuardCountry $pin.country } catch { Write-Host ('[节点] 更新守护期望国家失败：' + $_.Exception.Message) -ForegroundColor Yellow }
    if ($guardCfgChanged) { Write-Host ("[节点] 守护期望出口已改为 {0}" -f $pin.country) -ForegroundColor Green }
    try {
        $task = Get-ScheduledTask -TaskName 'ClaudeGuard' -ErrorAction Stop
        if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName 'ClaudeGuard'; Write-Host '[节点] 已暂停守护以加载新设置（防火墙拦截保持不变）' }
    } catch {}

    if (-not (Test-BPStrict $dataDir)) {
        if ((Get-BPConfigMode) -ne 'strict') {
            try { Save-BPOriginal $dataDir; Write-Host '[配置] 已保存白羊原始配置快照（关闭保护时还原）' -ForegroundColor Green }
            catch { Write-Host ('[配置] 保存原始配置快照失败：' + $_.Exception.Message) -ForegroundColor Yellow }
        }
        try { Set-BPStrict $dataDir; Write-Host ('[配置] 已套用严格配置（仅「{0}」· 零回落直连）' -f $pin.name) -ForegroundColor Green }
        catch { Write-Host ('[配置] 套用严格配置失败：' + $_.Exception.Message) -ForegroundColor Red; Done 1 ('套用严格配置失败：' + $_.Exception.Message) }
        $needRestart = $true
    } else {
        Write-Host '[配置] 当前已是严格配置' -ForegroundColor Green
    }
    # Clash 在跑但运行配置不是严格的（例如还在用白羊原始配置）→ 需要重启
    if ((Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue) -and -not (Test-BPRuntimePinned $dataDir)) { $needRestart = $true }
}

# ---------------------------------------------------------------- 启动 / 重启 Clash Verge
$exe = $null
try {
    $cfg = Get-Content -LiteralPath (Join-Path $root 'guard.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($r in @($cfg.coreRoots)) { $c = Join-Path $r 'clash-verge.exe'; if (Test-Path -LiteralPath $c) { $exe = $c; break } }
} catch {}
if (-not $exe) { foreach ($d in @('D:\Program Files\uu\Clash Verge', "$env:ProgramFiles\Clash Verge")) { $c = Join-Path $d 'clash-verge.exe'; if (Test-Path -LiteralPath $c) { $exe = $c; break } } }

$startedAt = Get-Date
$running = [bool](Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue)
if ($running -and $needRestart) {
    Write-Host '正在重启 Clash Verge 使新配置生效…'
    Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Get-Process -Name 'verge-mihomo', 'verge-mihomo-alpha' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $running = $false
}
if (-not $running -or -not (Test-TunUp)) {
    if (-not $exe) { Write-Host '找不到 clash-verge.exe，请手动启动 Clash Verge(TUN) 后再试。' -ForegroundColor Red; Done 1 '找不到 clash-verge.exe，请手动启动 Clash Verge(TUN) 后再试。' }
    if (-not (Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue)) { $startedAt = Get-Date; Start-Process explorer.exe -ArgumentList ('"{0}"' -f $exe) }
}

Write-Host '等待 TUN 与运行配置就绪（最长 90 秒）…'
$ready = $false
for ($i = 0; $i -lt 45; $i++) {
    $tunOk = Test-TunUp
    $cfgOk = $true
    if ($strict) {
        $rt = Join-Path $dataDir 'clash-verge.yaml'
        $fresh = (-not $needRestart) -or ((Test-Path -LiteralPath $rt) -and (Get-Item -LiteralPath $rt).LastWriteTime -ge $startedAt.AddSeconds(-1))
        $cfgOk = $fresh -and (Test-BPRuntimePinned $dataDir)
    }
    if ($tunOk -and $cfgOk) { $ready = $true; break }
    Start-Sleep -Seconds 2
}
if (-not (Test-TunUp)) { Write-Host 'Clash 未能在 90 秒内拉起 TUN，已放弃开启保护（网络保持当前状态）。' -ForegroundColor Red; Done 1 'Clash 未能在 90 秒内拉起 TUN，已放弃开启保护（网络保持当前状态）。' }
if (-not $ready) { Write-Host '严格配置没有生效：Clash 的运行配置不是只有锁定的节点，已放弃开启保护。' -ForegroundColor Red; Done 1 '严格配置没有生效（Clash 运行配置不是只有锁定的节点）。请在 Clash Verge 里确认当前订阅是「白羊加速」后重试。' }
Start-Sleep -Seconds 4

$rc = Invoke-GuardOp 'Resume'
if ($rc -eq 0) { Write-Host ''; Write-Host '保护已开启：防火墙默认拒绝 + 看门狗已启动。现在可以放心使用 Claude。' -ForegroundColor Green; Done 0 $(if ($strict -and $pin) { '保护已开启 · 锁定节点：' + $pin.name } else { '保护已开启' }) }
else { Write-Host ''; Write-Host '开启失败，已自动回滚到正常上网状态（见上方输出）。' -ForegroundColor Red; Done 1 '开启失败，已自动回滚到普通网络。常见原因：节点暂时不通或 Clash 未就绪，请稍后再试；详情见日志。' }
