<#
  热切换（保护开启时使用）：切换引擎 / 接管方式 / 锁定节点 / 节点来源，不关闭保护、不重启守护。
  原则：先把新的准备好（配置生成并校验、防火墙临时多放行新内核），再停旧的；浏览器在切换期间经系统代理桥接到内置内核。
  整个过程防火墙“出站默认拒绝”保持不变：切换中只有两个严格内核能出网，失败时是断开而不是直连。

  · 内置 TUN ⇄ 内置系统代理：同一个内核热重载，不重启
  · 换节点 / 换节点来源（内置引擎）：重新生成配置后热重载，不重启
  · Clash Verge → 内置：准备好内置内核后结束 Clash Verge，立即接管（约 2~4 秒新连接等待）
  · 内置 → Clash Verge：浏览器先桥接到内置内核，启动 Clash Verge 并确认严格配置生效后再停内置内核
  · 已有的长连接（下载、流式回复）会断开重连，这是换内核无法避免的

  -Engine Builtin|Verge  -NetMode Tun|SysProxy  -Source Baiyang|Local  -NodeB64 节点名(UTF-8+Base64)
#>
param([switch]$NoPause, [ValidateSet('', 'Builtin', 'Verge')][string]$Engine = '', [ValidateSet('', 'Tun', 'SysProxy')][string]$NetMode = '',
      [ValidateSet('', 'Baiyang', 'Local')][string]$Source = '', [string]$NodeB64 = '', [ValidateSet('Strict', 'Keep')][string]$ConfigMode = 'Strict')
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $a = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigMode {1}' -f $PSCommandPath, $ConfigMode
    if ($NoPause) { $a += ' -NoPause' }
    foreach ($kv in @(@('Engine', $Engine), @('NetMode', $NetMode), @('Source', $Source), @('NodeB64', $NodeB64))) { if ($kv[1]) { $a += (' -{0} {1}' -f $kv[0], $kv[1]) } }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $a
    exit
}

$root = 'C:\ProgramData\ClaudeGuard'
$sw0 = [Diagnostics.Stopwatch]::StartNew()
function Write-ToggleResult([bool]$ok, [string]$msg) {
    try {
        $f = Join-Path $root 'state\toggle-result.json'
        $o = [ordered]@{ action = 'switch'; ok = $ok; message = $msg; ts = (Get-Date).ToString('o'); seconds = [Math]::Round($sw0.Elapsed.TotalSeconds, 1) }
        [IO.File]::WriteAllText($f, ($o | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}
$script:SwitchLog = Join-Path $root 'logs\switch.log'
function Log([string]$m, [string]$c = 'Gray') {
    $line = '[{0:N1}s] {1}' -f $sw0.Elapsed.TotalSeconds, $m
    Write-Host $line -ForegroundColor $c
    # 每次切换的完整步骤都记下来（超过 512 KB 自动轮换），失败时可以在「保护日志」→「打开日志文件夹」里查看
    try {
        if ([IO.File]::Exists($script:SwitchLog) -and (New-Object IO.FileInfo($script:SwitchLog)).Length -gt 512KB) { Move-Item -LiteralPath $script:SwitchLog -Destination ($script:SwitchLog + '.1') -Force }
        [IO.File]::AppendAllText($script:SwitchLog, ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $line) + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}
function Find-Module([string]$name) {
    foreach ($c in @((Join-Path $PSScriptRoot $name), (Join-Path $root "bin\$name"), (Join-Path $PSScriptRoot "Config_Template\scripts\$name"))) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}
$script:total = 5
function Step([int]$n, [string]$text, [string]$sysProxy = '') { Write-BCProgress $n $script:total $text $sysProxy; Log ("[{0}/{1}] {2}" -f $n, $script:total, $text) 'Cyan' }

$script:finished = $false
function Done([bool]$ok, [string]$msg) {
    if ($script:finished) { return }
    $script:finished = $true
    Clear-BCSwitchMarker
    Write-BCProgress $script:total $script:total $msg '' -Done -Ok $ok
    Write-ToggleResult $ok $msg
    Log $msg $(if ($ok) { 'Green' } else { 'Red' })
    if (-not $NoPause) { Read-Host '按回车键关闭' | Out-Null }
    exit $(if ($ok) { 0 } else { 1 })
}

# 10.6 起：整个热切换由 cg-guard.exe 完成（没有新版 cg-guard 时才用下面的 PowerShell 流程）。
# 热切换中途出错不重做：cg-guard 已写好结果，保护保持开着（不会直连）。
$cgExe = Join-Path $root 'bin\cg-guard.exe'
if (-not $env:CG_NO_NATIVE -and (Test-Path -LiteralPath $cgExe)) {
    $cgv = ''; try { $cgv = (& $cgExe version 2>$null | Out-String) } catch {}
    if ($cgv -match 'cg-guard (\d+)\.(\d+)' -and (([int]$Matches[1] -gt 7) -or ([int]$Matches[1] -eq 7 -and [int]$Matches[2] -ge 4))) {
        $ca = @('switch', '--config', $ConfigMode)
        if ($NodeB64) { $ca += @('--node-b64', $NodeB64) }
        if ($Engine)  { $ca += @('--engine', $Engine) }
        if ($NetMode) { $ca += @('--net-mode', $NetMode) }
        if ($Source)  { $ca += @('--source', $Source) }
        & $cgExe @ca | Out-Host
        $cgCode = $LASTEXITCODE
        if (-not $NoPause) { Read-Host '按回车键关闭' | Out-Null }
        exit $(if ($cgCode -eq 0) { 0 } else { 1 })
    }
}
Write-Host '==== 热切换 ====' -ForegroundColor Yellow
$bp = Find-Module 'BaiyangProfile.ps1'; $bc = Find-Module 'BuiltinCore.ps1'
if (-not $bp -or -not $bc) { Write-ToggleResult $false '缺少模块，请在「维护」里更新到最新版。'; exit 1 }
. $bp; . $bc

# 只在保护开着时使用（没开保护时控制台会直接记下选择，下次开启生效）
$locked = $false
try { $locked = (@(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { $_.DefaultOutboundAction -ne 'Block' }).Count -eq 0) } catch {}
$guardRunning = $false
try { $guardRunning = ((Get-ScheduledTask -TaskName 'ClaudeGuard' -ErrorAction Stop).State -eq 'Running') } catch {}
if (-not $locked -or -not $guardRunning) { Write-ToggleResult $false '保护没有开启，无法热切换（请直接「开启保护」）。'; exit 1 }

# ---------------------------------------------------------------- 目标
$S = Get-BCSettings
$from = [pscustomobject]@{ engine = [string]$S.engine; netMode = [string]$S.netMode; source = [string]$S.subSource }
if ($from.engine -ne 'builtin') { $from.engine = 'verge' }
$to = [pscustomobject]@{
    engine  = $(if ($Engine) { $Engine.ToLower() } else { $from.engine })
    netMode = $(if ($NetMode) { $(if ($NetMode -eq 'SysProxy') { 'sysproxy' } else { 'tun' }) } else { $from.netMode })
    source  = $(if ($Source) { $Source.ToLower() } else { $from.source })
}
if ($to.netMode -ne 'sysproxy') { $to.netMode = 'tun' }
$wantNode = ''
if ($NodeB64) { try { $wantNode = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($NodeB64)) } catch {} }
$label = { param($e, $m) if ($e -eq 'builtin') { '内置引擎 · ' + $(if ($m -eq 'sysproxy') { '系统代理' } else { 'TUN' }) } else { 'Clash Verge' } }
$fromLbl = & $label $from.engine $from.netMode; $toLbl = & $label $to.engine $to.netMode
Log ("{0} → {1}{2}" -f $fromLbl, $toLbl, $(if ($wantNode) { '，节点：' + $wantNode } else { '' }))

# 失败回退时用的原始状态
$pinFile = Join-Path $root 'pinned-node.json'
$pinBackup = $(if (Test-Path -LiteralPath $pinFile) { [IO.File]::ReadAllText($pinFile) } else { $null })
$engineBackup = $(if (Test-Path -LiteralPath $script:BC_EngineFile) { [IO.File]::ReadAllText($script:BC_EngineFile) } else { $null })
function Restore-Backups {
    try { if ($pinBackup) { [IO.File]::WriteAllText($pinFile, $pinBackup, $script:BP_Utf8) } } catch {}
    try { if ($engineBackup) { [IO.File]::WriteAllText($script:BC_EngineFile, $engineBackup, $script:BP_Utf8) } } catch {}
}
function Resolve-Pin([string]$subText) {
    # 选了新节点：在节点来源里找到它并写入锁定记录；返回锁定节点（找不到返回 $null）
    if ($wantNode) {
        $n = Find-BPNode $subText ([pscustomobject]@{ name = $wantNode; fuzzy = @() })
        if (-not $n) { return $null }
        if (-not $n.country) { throw ("无法识别节点「{0}」所在的国家/地区" -f $wantNode) }
        Set-BPPinnedNode $n.name $n.country
        Log ("锁定节点：{0}（{1}）" -f $n.name, $n.country) 'Green'
    }
    return (Find-BPNode $subText (Get-BPPinnedNode))
}
function Stop-VergeFast {
    # 先结束界面（防止它重新拉起内核），再结束内核；等它的 TUN 网卡消失（最多 3 秒），不再固定等 4 秒
    Get-Process -Name 'baiyang', 'clash-verge' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process -Name 'verge-mihomo', 'verge-mihomo-alpha', 'clash-meta', 'mihomo', 'clash' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $t = [Diagnostics.Stopwatch]::StartNew()
    while ($t.Elapsed.TotalSeconds -lt 3) {
        if (@(Get-BCConflicts | Where-Object { $_.kind -eq 'tun' }).Count -eq 0) { break }
        Start-Sleep -Milliseconds 150
    }
}
function Clear-LocalProxy([switch]$OnlyOurs) {
    # 关掉指向本机的系统代理（内置内核 17897，或已退出的 Clash Verge 留下的 127.0.0.1:xxxx）
    try {
        $p = Get-BCSysProxy
        if (-not $p.enabled) { return }
        if (Test-BCSysProxyOurs) { Set-BCSysProxy $false; Log '系统代理已关闭（不再需要桥接）' }
        elseif (-not $OnlyOurs -and $p.server -match '^(http=)?127\.0\.0\.1:\d+$') { Set-BCSysProxy $false; Log ('已关闭本机代理 ' + $p.server) }
    } catch {}
}

Set-BCSwitchMarker 150 ("{0} → {1}" -f $fromLbl, $toLbl)

try {
# ================================================================= A. 内置 → 内置（接管方式 / 节点 / 来源）
if ($from.engine -eq 'builtin' -and $to.engine -eq 'builtin') {
    $script:total = 3
    Step 1 '准备新配置'
    if ($to.source -eq 'local' -and -not (Test-Path -LiteralPath (Get-BCSubFile 'local'))) { Restore-Backups; Done $false '没有导入过本地配置，请先导入。' }
    $subText = Get-BCSubText $to.source
    $pin = Resolve-Pin $subText
    if (-not $pin) { Restore-Backups; Done $false ('节点来源里找不到「{0}」，请更新订阅后重新选择。' -f $(if ($wantNode) { $wantNode } else { (Get-BPPinnedNode).name })) }
    $S.subSource = $to.source; $S.netMode = $to.netMode; $S.engine = 'builtin'
    Save-BCSettings $S
    $toSys = ($to.netMode -eq 'sysproxy'); $fromSys = ($from.netMode -eq 'sysproxy')
    if ($toSys -and -not $fromSys) {
        # TUN → 系统代理：先让浏览器走内核的本地代理端口（内核一直在跑），再关 TUN
        Write-BCProgress 1 3 '浏览器改走本地代理' 'bridge'; Set-BCSysProxy $true; Log ('系统代理 → 127.0.0.1:{0}' -f $S.mixedPort)
    }

    Step 2 $(if ($to.netMode -ne $from.netMode) { '内核热重载：' + $(if ($toSys) { '关闭 TUN' } else { '开启 TUN' }) } else { '内核热重载（新节点）' }) $(if ($toSys) { 'bridge' } else { '' })
    $r = Update-BCRuntime
    Log ('配置：' + $r.message)
    if (-not $r.ok -or $r.missing) {
        Restore-Backups; [void](Update-BCRuntime)
        if (-not $fromSys) { Clear-LocalProxy -OnlyOurs }
        Done $false ('新配置没有通过校验，已保持原样：' + $r.message)
    }
    $ok = Wait-BCCoreReady $to.netMode 12
    if ($ok -and $toSys) { [void](Wait-BCTunGone 6) }
    if (-not $ok -or ($toSys -and (Get-BCTunInfo).up)) {
        Log '热重载没有完全生效，重启内置内核…' 'Yellow'
        [void](Stop-BCCore); [void](Start-BCCore)
        $ok = Wait-BCCoreReady $to.netMode 30
    }
    if (-not $ok) {
        Log ('新模式没能就绪，回到原来的模式（内核日志：{0}）' -f (Get-BCCoreLogTail)) 'Red'
        Restore-Backups; [void](Update-BCRuntime -NoReload); [void](Stop-BCCore); [void](Start-BCCore)
        [void](Wait-BCCoreReady $from.netMode 30)
        if ($fromSys) { Set-BCSysProxy $true } else { Clear-LocalProxy -OnlyOurs }
        Done $false ('切换到 {0} 没有成功，已回到 {1}。' -f $toLbl, $fromLbl)
    }
    $nw = Wait-BCNodeWorks 12
    if (-not $nw.ok) {
        Log ('新设置下连不上节点：{0}；回到原来的设置' -f $nw.error) 'Red'
        Restore-Backups; [void](Update-BCRuntime)
        if (-not (Wait-BCCoreReady $from.netMode 12)) { [void](Stop-BCCore); [void](Start-BCCore); [void](Wait-BCCoreReady $from.netMode 30) }
        if ($fromSys) { Set-BCSysProxy $true } else { Clear-LocalProxy -OnlyOurs }
        Done $false ('切换后连不上节点（{0}），已回到 {1}。' -f $nw.error, $fromLbl)
    }
    Log ('节点连通，延迟 {0} ms' -f $nw.ms) 'Green'
    if (-not $toSys) { Clear-LocalProxy -OnlyOurs }
    if ($to.netMode -ne $from.netMode) { Clear-DnsClientCache -ErrorAction SilentlyContinue }

    Step 3 '守护跟随新设置' $(if ($toSys) { 'bridge' } else { 'clear' })
    [void](Set-BPGuardCountry $pin.country)
    [void](Set-BCGuardEngine 'builtin' $to.netMode)
    if (-not (Wait-BCGuardEngine 'builtin' 10)) { Log '守护还没确认新设置（不影响切换，稍后自动生效）' 'Yellow' }
    $real = @(); try { $real = @(Get-BCRealProxies) } catch {}
    if ($real.Count -ne 1 -or $real[0] -ne $pin.name) { Done $false ('内核运行配置异常（实际节点：{0}），守护会拦截 Claude，请重新开启保护。' -f ($real -join '、')) }
    Done $true ('已切换到 {0} · {1}（用时 {2:N0} 秒）' -f $toLbl, $pin.name, $sw0.Elapsed.TotalSeconds)
}

# ================================================================= B. Clash Verge → 内置
if ($from.engine -ne 'builtin' -and $to.engine -eq 'builtin') {
    $toSys = ($to.netMode -eq 'sysproxy')
    Step 1 '准备内置内核与配置'
    try { Log ('内核：' + (Install-BCCoreExe)) } catch { Restore-Backups; Done $false ('安装内置内核失败：' + $_.Exception.Message) }
    [void](Initialize-BCSub)
    if ($to.source -eq 'local' -and -not (Test-Path -LiteralPath (Get-BCSubFile 'local'))) { Restore-Backups; Done $false '没有导入过本地配置，请先导入。' }
    if ($to.source -eq 'baiyang') {
        $u = Update-BCSubscription
        Log ('订阅：' + $u.message) $(if ($u.ok) { 'Gray' } else { 'Yellow' })
    }
    $subText = Get-BCSubText $to.source
    if (-not $subText) { Restore-Backups; Done $false '内置引擎还没有可用的订阅。' }
    $pin = Resolve-Pin $subText
    if (-not $pin) { Restore-Backups; Done $false ('节点来源里找不到「{0}」。' -f $(if ($wantNode) { $wantNode } else { (Get-BPPinnedNode).name })) }
    $S.engine = 'builtin'; $S.netMode = $to.netMode; $S.subSource = $to.source
    Save-BCSettings $S
    $r = Update-BCRuntime -NoReload
    if (-not $r.ok -or $r.missing) { Restore-Backups; Done $false ('生成内置引擎配置失败：' + $r.message) }
    Log ('配置：' + $r.message)
    Register-BCTask

    Step 2 '防火墙临时放行内置内核'
    try { Add-BCTransitionAllow @($script:BC_Exe) @($script:BC_VergeCidr, $script:BC_TunCidr) } catch { Restore-Backups; Done $false ('放行内置内核失败：' + $_.Exception.Message) }

    if ($toSys) {
        Step 3 '启动内置内核，浏览器桥接过去'
        [void](Stop-BCCore); [void](Start-BCCore)
        if (-not (Wait-BCCoreReady 'sysproxy' 25)) {
            $why = Get-BCCoreLogTail
            [void](Stop-BCCore -Disable); Restore-Backups; Update-BCGuardConfigStamp
            Done $false ('内置内核没能启动，Clash Verge 保持不变。内核日志：' + $why)
        }
        Write-BCProgress 3 5 '浏览器改走内置内核' 'bridge'; Set-BCSysProxy $true
        Step 4 '关闭 Clash Verge' 'bridge'
        Stop-VergeFast
        Clear-DnsClientCache -ErrorAction SilentlyContinue
    } else {
        Step 3 '关闭 Clash Verge，内置内核接管 TUN' 'clear'
        Clear-LocalProxy
        [void](Stop-BCCore)
        Stop-VergeFast
        [void](Start-BCCore)
        if (-not (Wait-BCCoreReady 'tun' 30)) {
            Log ('内置内核没能在 30 秒内接管，改回 Clash Verge…（内核日志：{0}）' -f (Get-BCCoreLogTail)) 'Red'
            [void](Stop-BCCore -Disable); Restore-Backups
            $res = Find-Module 'Resume-恢复保护.ps1'; if (-not $res) { $res = Join-Path $root 'bin\Resume.ps1' }
            Clear-BCSwitchMarker
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $res -NoPause -Engine Verge -ConfigMode $ConfigMode | Out-Host
            Done $false '内置引擎没能接管，已改回 Clash Verge。'
        }
        Clear-DnsClientCache -ErrorAction SilentlyContinue
        Step 4 ('内置内核已接管（{0:N1} 秒）' -f $sw0.Elapsed.TotalSeconds) 'clear'
    }
    # 再扫一次：Clash Verge 界面若刚好在重启内核，这里补刀（被防火墙隔离，本来也连不出去）
    $left = @(Get-BCConflicts | Where-Object { $_.kind -eq 'process' }).Count
    if ($left -gt 0) { $left = Stop-BCConflicts; if ($left -gt 0) { Log "仍有 $left 个 Clash 进程无法结束（已被防火墙隔离）" 'Yellow' } }

    # 真实验证：内核经锁定节点请求一次。不通就改回 Clash Verge（不把“内核启动了但连不上节点”当成功）
    Log '验证内置内核能经锁定节点联网…'
    $nw = Wait-BCNodeWorks 15
    if (-not $nw.ok) {
        Log ('内置内核连不上节点：{0}；改回 Clash Verge…' -f $nw.error) 'Red'
        Clear-LocalProxy -OnlyOurs
        [void](Stop-BCCore -Disable); Restore-Backups
        $res = Find-Module 'Resume-恢复保护.ps1'; if (-not $res) { $res = Join-Path $root 'bin\Resume.ps1' }
        Clear-BCSwitchMarker
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $res -NoPause -Engine Verge -ConfigMode $ConfigMode | Out-Host
        Done $false ('内置内核连不上节点（{0}），已改回 Clash Verge。' -f $nw.error)
    }
    Log ('节点连通，延迟 {0} ms' -f $nw.ms) 'Green'

    Step 5 '守护切到内置引擎，收回 Clash Verge 的放行' $(if ($toSys) { 'bridge' } else { 'clear' })
    [void](Set-BPGuardCountry $pin.country)
    [void](Set-BCGuardEngine 'builtin' $to.netMode)
    if (-not (Wait-BCGuardEngine 'builtin' 10)) { Log '守护还没确认新设置（稍后自动生效）' 'Yellow' }
    # Clash Verge 不再被借用：配置还原成白羊原始配置，以后单独打开它就是原样
    try { if ((Get-BPConfigMode) -eq 'strict') { Log ('Clash Verge：' + (Restore-BPOriginal (Get-BPDataDir))) } } catch { Log ('还原 Clash Verge 配置失败（不影响内置引擎）：' + $_.Exception.Message) 'Yellow' }
    $real = @(); try { $real = @(Get-BCRealProxies) } catch {}
    if ($real.Count -ne 1 -or $real[0] -ne $pin.name) { Done $false ('内置内核运行配置异常（实际节点：{0}），守护会拦截 Claude。' -f ($real -join '、')) }
    Done $true ('已切换到 {0} · {1}（用时 {2:N0} 秒）' -f $toLbl, $pin.name, $sw0.Elapsed.TotalSeconds)
}

# ================================================================= C. 内置 → Clash Verge
if ($from.engine -eq 'builtin' -and $to.engine -ne 'builtin') {
    $strict = ($ConfigMode -eq 'Strict')
    Step 1 '准备 Clash Verge 严格配置'
    $vergeExe = Get-BPVergeExe
    if (-not $vergeExe) { Done $false '找不到 clash-verge.exe，无法切换到 Clash Verge。' }
    $dataDir = Get-BPDataDir
    $pin = Get-BPPinnedNode
    if ($strict) {
        $u = Update-BPSubscription $dataDir
        Log ('订阅：' + $u.message) $(if ($u.ok) { 'Gray' } else { 'Yellow' })
        $bItem = Get-BPBaiyangItem (Get-BPProfiles $dataDir)
        $vText = $(if ($bItem) { Read-BPText (Join-Path $dataDir "profiles\$($bItem.File)") } else { '' })
        try { $pin = Resolve-Pin $vText } catch { Restore-Backups; Done $false $_.Exception.Message }
        if (-not $pin) { Restore-Backups; Done $false ('Clash Verge 的白羊订阅里没有「{0}」（本地导入的节点只能用于内置引擎）。' -f $(if ($wantNode) { $wantNode } else { (Get-BPPinnedNode).name })) }
        if (-not (Test-BPStrict $dataDir)) {
            if ((Get-BPConfigMode) -ne 'strict') { try { Save-BPOriginal $dataDir; Log '已保存白羊原始配置快照' } catch {} }
            try { Set-BPStrict $dataDir; Log ('已套用严格配置（仅「{0}」）' -f $pin.name) 'Green' } catch { Restore-Backups; Done $false ('套用严格配置失败：' + $_.Exception.Message) }
        }
    }

    Step 2 '防火墙临时放行 Clash Verge 内核'
    try { Add-BCTransitionAllow @(Get-BCVergeCorePaths) @($script:BC_TunCidr, $script:BC_VergeCidr) } catch { Restore-Backups; Done $false ('放行 Clash Verge 内核失败：' + $_.Exception.Message) }

    Step 3 '浏览器桥接到内置内核，让出 TUN' 'bridge'
    Set-BCSysProxy $true
    $wasTun = ($from.netMode -ne 'sysproxy')
    if ($wasTun) {
        $S.netMode = 'sysproxy'; Save-BCSettings $S
        $r = Update-BCRuntime
        if (-not $r.ok) { Log ('关闭内置 TUN 失败：' + $r.message) 'Yellow' }
        if (-not (Wait-BCTunGone 8)) { Log '热重载没关掉 TUN，重启内置内核（无 TUN）' 'Yellow'; [void](Stop-BCCore); [void](Start-BCCore); [void](Wait-BCCoreReady 'sysproxy' 20) }
    }

    Step 4 '启动 Clash Verge 并等待严格配置生效' 'bridge'
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -like '*\白羊加速\*' } | Stop-Process -Force -ErrorAction SilentlyContinue
    $startedAt = Get-Date
    if (Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue) {
        Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Get-Process -Name 'verge-mihomo', 'verge-mihomo-alpha' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
    }
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $vergeExe)     # 经 explorer 以普通用户身份启动
    $ready = $false
    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep -Milliseconds 700
        $a = Get-NetAdapter -Name 'Mihomo' -ErrorAction SilentlyContinue
        if (-not $a -or $a.Status -ne 'Up') { continue }
        if ($strict) {
            $rt = Join-Path $dataDir 'clash-verge.yaml'
            if (-not (Test-Path -LiteralPath $rt) -or (Get-Item -LiteralPath $rt).LastWriteTime -lt $startedAt.AddSeconds(-1)) { continue }
            if (-not (Test-BPRuntimePinned $dataDir)) { continue }
        }
        $ready = $true; break
    }
    if (-not $ready) {
        Log 'Clash Verge 没能在约 60 秒内就绪，回到内置引擎' 'Red'
        Get-Process -Name 'clash-verge', 'verge-mihomo', 'verge-mihomo-alpha' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Restore-Backups
        $r = Update-BCRuntime
        if (-not (Wait-BCCoreReady $from.netMode 15)) { [void](Stop-BCCore); [void](Start-BCCore); [void](Wait-BCCoreReady $from.netMode 30) }
        if ($from.netMode -ne 'sysproxy') { Clear-LocalProxy -OnlyOurs }
        Update-BCGuardConfigStamp
        Done $false ('Clash Verge 没能就绪（TUN 或严格配置未生效），已回到 {0}。' -f $fromLbl)
    }
    Log 'Clash Verge 已就绪' 'Green'

    Step 5 '停止内置内核，守护切到 Clash Verge' 'clear'
    Clear-LocalProxy -OnlyOurs
    [void](Stop-BCCore -Disable)
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    $S = Get-BCSettings; $S.engine = 'verge'; $S.netMode = $from.netMode; Save-BCSettings $S   # 记住内置引擎原来的接管方式
    [void](Set-BPGuardCountry $pin.country)
    [void](Set-BCGuardEngine 'verge')
    if (-not (Wait-BCGuardEngine 'verge' 10)) { Log '守护还没确认新设置（稍后自动生效）' 'Yellow' }
    Done $true ('已切换到 Clash Verge · {0}（用时 {1:N0} 秒）' -f $pin.name, $sw0.Elapsed.TotalSeconds)
}

# ================================================================= D. Clash Verge → Clash Verge（只换节点）
if ($from.engine -ne 'builtin' -and $to.engine -ne 'builtin') {
    # 旧引擎换节点需要重启 Clash Verge，交给开启保护流程（它会保持防火墙默认拒绝）
    Clear-BCSwitchMarker
    $res = Find-Module 'Resume-恢复保护.ps1'; if (-not $res) { $res = Join-Path $root 'bin\Resume.ps1' }
    $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $res, '-NoPause', '-ConfigMode', $ConfigMode)
    if ($NodeB64) { $args2 += @('-NodeB64', $NodeB64) }
    $t0 = Get-Date
    & powershell.exe @args2 | Out-Host
    $rr = $null; try { $rr = Get-Content -LiteralPath (Join-Path $root 'state\toggle-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    if ($rr -and [DateTime]::Parse([string]$rr.ts) -ge $t0.AddSeconds(-2)) { Done ([bool]$rr.ok) ([string]$rr.message) }
    Done ($LASTEXITCODE -eq 0) $(if ($LASTEXITCODE -eq 0) { '已切换锁定节点' } else { '切换节点失败，详情见日志' })
}
} catch {
    Log ('意外错误：' + $_.Exception.Message) 'Red'
    Done $false ('切换出错：' + $_.Exception.Message + '。保护仍开着（不会直连），可以再试一次或关闭保护。')
} finally {
    if (-not $script:finished) { Clear-BCSwitchMarker }
}
Done $true '没有需要切换的内容'
