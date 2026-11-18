<#
  更新白羊订阅（由「Claude 保护」控制台在后台隐藏调用，普通用户权限即可）
  · 内置引擎：拉取订阅到 core\sub；锁定节点的入口变了 → 通知守护（SYSTEM）重新生成运行配置并热重载内核，不断网
  · Clash Verge 引擎：拉取订阅；只有锁定节点的入口地址/端口变了，才重启 Clash Verge 让新端口生效
  · 结果写入 %LOCALAPPDATA%\ClaudeGuardHub\sub-result.json 供控制台显示/通知
  -Auto：由控制台自动触发（出口检测连续失败 / 定时检查）
#>
param([switch]$Auto)
$ErrorActionPreference = 'Continue'
$resultFile = Join-Path $env:LOCALAPPDATA 'ClaudeGuardHub\sub-result.json'
New-Item -ItemType Directory -Path (Split-Path $resultFile) -Force | Out-Null

function Write-Result($o) {
    $o['auto'] = [bool]$Auto
    $o['ts'] = (Get-Date).ToString('o')
    [IO.File]::WriteAllText($resultFile, ($o | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}

function Send-GuardCommand([string]$Cmd) {
    $dir = 'C:\ProgramData\ClaudeGuard\commands'
    $tmp = Join-Path $dir ('cmd.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($tmp, (@{ cmd = $Cmd; ts = (Get-Date).ToString('o') } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination (Join-Path $dir 'cmd.json') -Force
}

try {
    . (Join-Path $PSScriptRoot 'BaiyangProfile.ps1')
    $builtin = $false
    $bc = Join-Path $PSScriptRoot 'BuiltinCore.ps1'
    if (Test-Path -LiteralPath $bc) { . $bc; $builtin = ((Get-BCEngine) -eq 'builtin') }
    $restarted = $false
    if ($builtin) {
        $u = Update-BCSubscription
        $msg = [string]$u.message
        $active = ([string](Get-BCSettings).subSource -eq 'baiyang')
        $guardOn = [bool](Get-BCCoreProcess)
        if ($u.ok -and $u.changed -and $active -and $guardOn) {
            # 运行配置只能由守护（SYSTEM）生成：这里只通知它，它会校验后热重载
            try { Send-GuardCommand 'reload-core'; if ($u.nodeChanged) { $restarted = $true; $msg += '，已通知守护热重载内置内核（不断网）' } }
            catch { $msg += '，但通知守护失败：' + $_.Exception.Message }
        }
        if ($u.ok -and -not $active) { $msg += '（当前使用的是导入的本地配置，白羊订阅更新不影响运行）' }
    } else {
        $dataDir = Get-BPDataDir
        $u = Update-BPSubscription $dataDir
        $msg = [string]$u.message
        if ($u.ok -and $u.nodeChanged -and (Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue)) {
            if (Restart-BPClash) { $restarted = $true; $msg += '，已重启 Clash 使新端口生效' }
        }
    }
    Write-Result ([ordered]@{ ok = [bool]$u.ok; changed = [bool]$u.changed; nodeChanged = [bool]$u.nodeChanged; restarted = $restarted; host = [string]$u.host; message = $msg })
} catch {
    Write-Result ([ordered]@{ ok = $false; changed = $false; nodeChanged = $false; restarted = $false; host = ''; message = ('更新订阅出错：' + $_.Exception.Message) })
}
