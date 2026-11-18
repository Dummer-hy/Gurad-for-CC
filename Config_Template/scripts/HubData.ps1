<#
  HubData.ps1 —— 新控制台（cg-hub.exe）按需调用的数据助手，普通用户权限，用完即退（不常驻）。
  复用 BaiyangProfile.ps1 / BuiltinCore.ps1 里已经验证过的解析逻辑，输出一行 JSON 到标准输出。
    -Mode Config  -Engine verge|builtin -Source baiyang|local   订阅信息 + 节点列表 + Clash 配置状态 + 冲突程序
    -Mode Procs                                                  正在运行的 Claude 程序
    -Mode KillClaude                                             结束所有 Claude 程序
    -Mode Import [-Path 文件]                                    导入本地 Clash 配置（不给路径时弹出选择框）
#>
param(
    [ValidateSet('Config', 'Procs', 'KillClaude', 'Import')][string]$Mode = 'Config',
    [string]$Engine = 'verge',
    [string]$Source = 'baiyang',
    [string]$Path = ''
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

function Out-Json($o) { [Console]::Out.Write(($o | ConvertTo-Json -Depth 6 -Compress)) }

$bp = $false; $bc = $false
try { . (Join-Path $PSScriptRoot 'BaiyangProfile.ps1'); $bp = $true } catch {}
if ($bp) { try { . (Join-Path $PSScriptRoot 'BuiltinCore.ps1'); $bc = $true } catch {} }
if (-not $bp) { Out-Json @{ ok = $false; error = '缺少 BaiyangProfile.ps1，请在「维护」里更新到最新版' }; exit 0 }

function Get-ClaudeKind($p) {
    $path = [string]$p.ExecutablePath
    if ($path -match 'AnthropicClaude') { return 'Claude 桌面版' }
    if ($path -match '\\claude-code\\' -or $path -match '\.local\\bin') { return 'Claude Code' }
    if ($path -match 'anthropic\.claude-code') { return 'Claude Code（VS Code）' }
    if ($p.Name -match '^(node|bun)') { return 'Claude Code（Node）' }
    return 'Claude'
}

function Get-NodeDetail([string]$line, $m) {
    if ($line -match 'name:\s*([^,}]+)') { $m.node = $Matches[1].Trim() }
    if ($line -match 'type:\s*([^,}\s]+)') { $m.ntype = $Matches[1] }
    if ($line -match 'server:\s*([^,}\s]+)') { $m.server = $Matches[1] }
    if ($line -match 'port:\s*(\d+)') { $m.port = $Matches[1] }
    if ($line -match 'flow:\s*([^,}\s]+)') { $m.flow = $Matches[1] }
    $m.reality = ($line -match 'reality-opts')
}

try {
    switch ($Mode) {
        'Procs' {
            $out = @()
            foreach ($p in @(Get-BPClaudeProcesses)) {
                $start = ''; try { if ($p.CreationDate) { $start = ([datetime]$p.CreationDate).ToString('o') } } catch {}
                $path = [string]$p.ExecutablePath
                $out += [ordered]@{ kind = (Get-ClaudeKind $p); pid = [int]$p.ProcessId; mem = [double]$p.WorkingSetSize; start = $start
                                    path = $(if ($path) { $path -replace [regex]::Escape($env:USERPROFILE), '~' } else { '' }) }
            }
            Out-Json @{ ok = $true; procs = @($out | Sort-Object { $_.kind }, { $_.pid }) }
        }
        'KillClaude' {
            $r = Stop-BPClaudeProcesses
            Out-Json @{ ok = $true; found = [int]$r.Found; left = [int]$r.Left }
        }
        'Import' {
            if (-not $bc) { throw '缺少内置引擎模块（BuiltinCore.ps1）' }
            if (-not $Path) {
                Add-Type -AssemblyName System.Windows.Forms
                $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false; WindowState = 'Minimized' }
                $dlg = New-Object System.Windows.Forms.OpenFileDialog
                $dlg.Title = '选择 Clash / mihomo 配置文件（只会使用其中的节点，规则一律用内置严格规则）'
                $dlg.Filter = 'Clash 配置 (*.yaml;*.yml)|*.yaml;*.yml|所有文件 (*.*)|*.*'
                if ($dlg.ShowDialog($owner) -ne 'OK') { Out-Json @{ ok = $false; cancelled = $true }; break }
                $Path = $dlg.FileName
            }
            $n = Import-BCLocal $Path
            Out-Json @{ ok = $true; nodes = [int]$n; name = (Split-Path $Path -Leaf) }
        }
        'Config' {
            $pin = Get-BPPinnedNode
            $builtinView = ($bc -and $Engine -eq 'builtin')
            $m = [ordered]@{ ok = $false; builtinView = $builtinView; source = $Source; nodes = @() }
            $file = ''
            if ($builtinView) {
                $file = Get-BCSubFile $Source
                $meta = Get-BCSubMeta $Source
                if (Test-Path -LiteralPath $file) {
                    $m.ok = $true
                    if ($Source -eq 'local') { $m.name = $(if ($meta) { [string]$meta.name } else { '本地配置' }); $m.host = '' }
                    else {
                        $m.name = '白羊加速'; $m.host = $(if ($meta) { [string]$meta.host } else { '' })
                        foreach ($k in @('upload', 'download', 'total', 'expire')) { if ($meta -and $meta.$k) { $m[$k] = [double]$meta.$k } }
                    }
                }
            } else {
                $d = Get-BPDataDir
                $prof = Get-BPProfiles $d
                $item = Get-BPBaiyangItem $prof
                if ($item) {
                    $m.ok = $true
                    $file = Join-Path $d "profiles\$($item.File)"
                    $m.host = ([regex]::Match($item.Url, '^https?://([^/]+)')).Groups[1].Value
                    for ($i = $item.Start; $i -le $item.End; $i++) {
                        $l = $prof.Lines[$i]
                        if ($l -match '^  name:\s*(.+)$') { $m.name = $Matches[1].Trim() }
                        elseif ($l -match '^    (upload|download|total|expire):\s*(\d+)') { $m[$Matches[1]] = [double]$Matches[2] }
                        elseif ($l -match '^    update_interval:\s*(\d+)') { $m.interval = [int]$Matches[1] }
                    }
                }
            }
            if ($m.ok -and $file -and (Test-Path -LiteralPath $file)) {
                $text = Read-BPText $file
                $m.nodes = @(Get-BPNodeList $text | ForEach-Object {
                    [ordered]@{ name = $_.name; type = $_.type; country = $_.country; cname = $(if ($_.country) { Get-BPCountryName $_.country } else { '' })
                                unsupported = [bool]($_.country -and ($script:BP_ClaudeUnsupported -contains $_.country)) } })
                $line = Get-BPNodeLine $text $pin
                if ($line) { Get-NodeDetail $line $m }
                try { $m.fileTime = (Get-Item -LiteralPath $file).LastWriteTime.ToString('o') } catch {}
            }
            $m.nodeCount = @($m.nodes).Count
            $localName = ''
            if ($bc) { $lm = Get-BCSubMeta 'local'; if ($lm) { $localName = [string]$lm.name } }
            $conf = @()
            if ($bc) { $conf = @(Get-BCConflicts | ForEach-Object { [ordered]@{ kind = $_.kind; name = $_.name; detail = $_.detail } }) }
            Out-Json ([ordered]@{
                ok = $true; bp = $bp; bc = $bc
                vmode = (Get-BPConfigMode)
                pin = [ordered]@{ name = $pin.name; country = $pin.country; cname = (Get-BPCountryName $pin.country); since = $pin.since }
                sub = $m
                localName = $localName
                localExists = [bool]($bc -and (Test-Path -LiteralPath (Get-BCSubFile 'local')))
                conflicts = $conf
            })
        }
    }
} catch {
    Out-Json @{ ok = $false; error = $_.Exception.Message }
}
