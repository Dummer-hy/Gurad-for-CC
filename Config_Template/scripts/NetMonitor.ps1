<#
  连接 / 内核日志监视（只读 + 关闭连接），供控制台的「连接」「内核日志」页面在后台线程里使用。
  · 内置引擎：127.0.0.1:<apiPort> + 密钥
  · Clash Verge：它的内核只开了命名管道（\\.\pipe\verge-mihomo-*），按实际存在的管道连接
  · 连接属于哪个程序：用 Windows 的套接字表（连接的源地址:端口 = 程序自己的套接字）反查进程，
    不需要改内核配置（两个内核的 find-process-mode 都保持 off）
#>

$script:NM_Root = 'C:\ProgramData\ClaudeGuard'
$script:NM_Js = $null
$script:NM_PidNames = @{}

function Initialize-NMTypes([switch]$NoSock) {
    if (-not $NoSock -and -not ('CgSock' -as [type])) {
        try { Add-NMSockType } catch { if (-not ('CgSock' -as [type])) { throw } }   # 另一个线程刚好先编译好了也没关系
    }
    Add-Type -AssemblyName System.Web.Extensions
    $script:NM_Js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $script:NM_Js.MaxJsonLength = [int]::MaxValue
}

function Add-NMSockType {
        Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class CgSock {
  [DllImport("iphlpapi.dll")] static extern uint GetExtendedTcpTable(IntPtr p, ref int len, bool sort, int af, int cls, uint reserved);
  [DllImport("iphlpapi.dll")] static extern uint GetExtendedUdpTable(IntPtr p, ref int len, bool sort, int af, int cls, uint reserved);
  // 键："t|u" + "本地IP:端口" → PID；UDP 另记 "u*:端口"（UDP 套接字常绑定 0.0.0.0）
  public static Dictionary<string,int> Map() { var d = new Dictionary<string,int>(); Fill(true, d); Fill(false, d); return d; }
  static int Port(int v) { return ((v & 0xFF) << 8) | ((v >> 8) & 0xFF); }
  static void Fill(bool tcp, Dictionary<string,int> d) {
    for (int attempt = 0; attempt < 3; attempt++) {
      int len = 0;
      if (tcp) GetExtendedTcpTable(IntPtr.Zero, ref len, false, 2, 5, 0); else GetExtendedUdpTable(IntPtr.Zero, ref len, false, 2, 1, 0);
      len += 8192; IntPtr buf = Marshal.AllocHGlobal(len);
      try {
        uint r = tcp ? GetExtendedTcpTable(buf, ref len, false, 2, 5, 0) : GetExtendedUdpTable(buf, ref len, false, 2, 1, 0);
        if (r == 122) continue;            // 表在两次调用之间变大了，重试
        if (r != 0) return;
        int n = Marshal.ReadInt32(buf); int rs = tcp ? 24 : 12;
        for (int i = 0; i < n; i++) {
          IntPtr row = IntPtr.Add(buf, 4 + i * rs);
          uint addr = (uint)Marshal.ReadInt32(row, tcp ? 4 : 0);
          int port = Port(Marshal.ReadInt32(row, tcp ? 8 : 4));
          int pid = Marshal.ReadInt32(row, tcp ? 20 : 8);
          string ip = new System.Net.IPAddress((long)addr).ToString();
          string pre = tcp ? "t" : "u";
          d[pre + ip + ":" + port] = pid;
          if (!tcp && !d.ContainsKey("u*:" + port)) d["u*:" + port] = pid;
        }
        return;
      } finally { Marshal.FreeHGlobal(buf); }
    }
  }
}
'@
}

# ------------------------------------------------------------------ 找到正在运行的内核的控制接口
function Read-NMText([string]$f) { try { if ([IO.File]::Exists($f)) { return [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) } } catch {}; return '' }

function Get-NMEndpoint {
    # 返回 @{ engine; kind = http|pipe; port; pipe; secret; label } ；内核没运行返回 @{ ok = $false; why }
    $eng = $null; try { $eng = (Read-NMText (Join-Path $script:NM_Root 'engine.json')) | ConvertFrom-Json } catch {}
    if ($eng -and [string]$eng.engine -eq 'builtin') {
        if (@([System.Diagnostics.Process]::GetProcessesByName('cg-mihomo')).Count -eq 0) { return @{ ok = $false; engine = 'builtin'; why = '内置内核没有运行' } }
        $port = $(if ($eng.apiPort) { [int]$eng.apiPort } else { 19097 })
        return @{ ok = $true; engine = 'builtin'; kind = 'http'; port = $port; secret = [string]$eng.secret; label = '内置内核' }
    }
    $pipe = $null
    try { $pipe = @([IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -match '\\verge-mihomo' }) | Select-Object -First 1 } catch {}
    $secret = ''
    $rt = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml'
    $y = Read-NMText $rt
    if ($y -match "(?m)^secret:\s*['""]?([^'""\r\n]*)") { $secret = $Matches[1].Trim() }
    if ($pipe) { return @{ ok = $true; engine = 'verge'; kind = 'pipe'; pipe = ($pipe -replace '^.*\\', ''); secret = $secret; label = 'Clash Verge' } }
    if ($y -match "(?m)^external-controller:\s*['""]?127\.0\.0\.1:(\d+)") { return @{ ok = $true; engine = 'verge'; kind = 'http'; port = [int]$Matches[1]; secret = $secret; label = 'Clash Verge' } }
    if (@(Get-Process -Name 'verge-mihomo', 'verge-mihomo-alpha' -ErrorAction SilentlyContinue).Count -eq 0) { return @{ ok = $false; engine = 'verge'; why = 'Clash Verge 内核没有运行' } }
    return @{ ok = $false; engine = 'verge'; why = '找不到 Clash Verge 的控制接口' }
}

# ------------------------------------------------------------------ 极简 HTTP/1.1（TCP 与命名管道共用，按字节解析，支持 chunked）
function Open-NMRequest($ep, [string]$Method, [string]$Path, [int]$TimeoutMs = 2000) {
    # $TimeoutMs = 读取超时；0 = 不限（用于日志流：内核在第一条日志出现前不会回响应头）。连接本身最多等 3 秒
    $client = $null; $stream = $null
    $connMs = $(if ($TimeoutMs -le 0) { 3000 } else { [Math]::Min($TimeoutMs, 3000) })
    if ($ep.kind -eq 'pipe') {
        $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $ep.pipe, [System.IO.Pipes.PipeDirection]::InOut)
        $client.Connect($connMs); $stream = $client
    } else {
        $client = New-Object System.Net.Sockets.TcpClient
        $ar = $client.BeginConnect('127.0.0.1', [int]$ep.port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($connMs)) { $client.Close(); throw '连接控制接口超时' }
        $client.EndConnect($ar)
        $client.ReceiveTimeout = $TimeoutMs; $client.SendTimeout = 3000
        $stream = $client.GetStream()
    }
    $h = "$Method $Path HTTP/1.1`r`nHost: 127.0.0.1`r`nUser-Agent: ClaudeGuardHub`r`n"
    if ($ep.secret) { $h += "Authorization: Bearer $($ep.secret)`r`n" }
    if ($Method -ne 'GET') { $h += "Content-Length: 0`r`n" }
    $h += "Connection: close`r`n`r`n"
    $b = [Text.Encoding]::ASCII.GetBytes($h); $stream.Write($b, 0, $b.Length); $stream.Flush()
    # 响应头：逐字节读到空行
    $hb = New-Object System.IO.MemoryStream; $last4 = 0
    while ($true) {
        $x = $stream.ReadByte(); if ($x -lt 0) { throw '控制接口提前关闭了连接' }
        $hb.WriteByte([byte]$x); $last4 = (($last4 -shl 8) -bor $x) -band 0xFFFFFFFF
        if ($last4 -eq 0x0D0A0D0A) { break }
        if ($hb.Length -gt 65536) { throw '响应头过大' }
    }
    $head = [Text.Encoding]::ASCII.GetString($hb.ToArray())
    $status = 0; if ($head -match '^HTTP/1\.\d (\d{3})') { $status = [int]$Matches[1] }
    $chunked = ($head -match '(?im)^Transfer-Encoding:\s*chunked')
    $len = -1; if ($head -match '(?im)^Content-Length:\s*(\d+)') { $len = [int64]$Matches[1] }
    return @{ client = $client; stream = $stream; status = $status; chunked = $chunked; length = $len }
}
function Close-NMRequest($r) { try { $r.stream.Dispose() } catch {}; try { $r.client.Close() } catch {} }

function Read-NMExact($stream, [byte[]]$buf, [int]$count) {
    $got = 0
    while ($got -lt $count) { $n = $stream.Read($buf, $got, $count - $got); if ($n -le 0) { return $got }; $got += $n }
    return $got
}
function Read-NMLineBytes($stream) {
    $sb = New-Object System.Text.StringBuilder
    while ($true) { $x = $stream.ReadByte(); if ($x -lt 0) { return $null }; if ($x -eq 10) { break }; if ($x -ne 13) { [void]$sb.Append([char]$x) } }
    return $sb.ToString()
}
function Read-NMChunk($r) {
    # 读下一块正文（字节数组）；结束返回 $null
    if ($r.chunked) {
        $line = Read-NMLineBytes $r.stream
        if ($null -eq $line) { return $null }
        $line = ($line -split ';')[0].Trim()
        if (-not $line) { $line = Read-NMLineBytes $r.stream; if (-not $line) { return $null }; $line = ($line -split ';')[0].Trim() }
        $size = [Convert]::ToInt32($line, 16)
        if ($size -eq 0) { return $null }
        $buf = New-Object byte[] $size
        $got = Read-NMExact $r.stream $buf $size
        [void](Read-NMLineBytes $r.stream)   # 块尾的 CRLF
        if ($got -lt $size) { return $null }
        return $buf
    }
    if ($r.length -eq 0) { return $null }
    $want = $(if ($r.length -gt 0) { [int][Math]::Min(65536, $r.length) } else { 65536 })
    $buf = New-Object byte[] $want
    $n = $r.stream.Read($buf, 0, $want)
    if ($n -le 0) { return $null }
    if ($r.length -gt 0) { $r.length -= $n }
    if ($n -lt $want) { $t = New-Object byte[] $n; [Array]::Copy($buf, $t, $n); return $t }
    return $buf
}

function Invoke-NMApi($ep, [string]$Method, [string]$Path, [int]$TimeoutMs = 2000) {
    $r = Open-NMRequest $ep $Method $Path $TimeoutMs
    try {
        $ms = New-Object System.IO.MemoryStream
        while ($true) { $c = Read-NMChunk $r; if ($null -eq $c) { break }; $ms.Write($c, 0, $c.Length) }
        $body = [Text.Encoding]::UTF8.GetString($ms.ToArray())
        if ($r.status -ge 400) { throw ('控制接口返回 {0}：{1}' -f $r.status, $body.Trim()) }
        return $body
    } finally { Close-NMRequest $r }
}

# ------------------------------------------------------------------ 进程反查
function Get-NMProcName([int]$ProcId) {
    if ($ProcId -le 0) { return '' }
    $c = $script:NM_PidNames[$ProcId]
    if ($c -and ((Get-Date) - $c.t).TotalSeconds -lt 120) { return $c.name }
    $n = ''
    try { $n = [System.Diagnostics.Process]::GetProcessById($ProcId).ProcessName } catch {}
    if ($ProcId -eq 4) { $n = 'System' }
    $script:NM_PidNames[$ProcId] = @{ name = $n; t = Get-Date }
    return $n
}

function Get-NMConnections($ep) {
    # 返回 @{ down; up; list = 原始连接字典数组 }
    $o = $script:NM_Js.DeserializeObject((Invoke-NMApi $ep 'GET' '/connections' 2500))
    $list = @(); if ($o -and $o['connections']) { $list = @($o['connections']) }
    return @{ down = [double]$o['downloadTotal']; up = [double]$o['uploadTotal']; list = $list }
}

function Format-NMBytes([double]$n) {
    if ($n -lt 1024) { return ('{0:N0} B' -f $n) }
    $u = @('KB', 'MB', 'GB', 'TB'); $i = -1
    do { $n = $n / 1024; $i++ } while ($n -ge 1024 -and $i -lt 3)
    return ('{0:N1} {1}' -f $n, $u[$i])
}
function Format-NMSpan([TimeSpan]$s) {
    if ($s.TotalSeconds -lt 60) { return ('{0:N0} 秒' -f [Math]::Max(0, $s.TotalSeconds)) }
    if ($s.TotalMinutes -lt 60) { return ('{0} 分 {1} 秒' -f [int][Math]::Floor($s.TotalMinutes), $s.Seconds) }
    return ('{0} 时 {1} 分' -f [int][Math]::Floor($s.TotalHours), $s.Minutes)
}

# ------------------------------------------------------------------ 共享状态（控制台与两个后台线程之间）
function New-NMState {
    return [hashtable]::Synchronized(@{
        stop = $false; gen = 1; visible = $false; wake = $false
        label = ''; status = ''; connSeq = 0; conns = @(); totals = $null; top = ''
        closeQ  = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        closedQ = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        logQ    = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        errs    = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        userClosed = [hashtable]::Synchronized(@{})
        logStatus = ''; logLabel = ''; logSeq = 0L
    })
}

function Get-NMGuardContext {
    # 断开原因参考：守护是否在拦截 / 是否正在热切换
    $r = @{ lock = ''; switching = '' }
    try {
        $st = (Read-NMText (Join-Path $script:NM_Root 'state\guard_state.json')) | ConvertFrom-Json
        if ($st) {
            if ([string]$st.mode -eq 'LOCKED') { $r.lock = [string]$st.reason }
            if ($st.switching) { $r.switching = [string]$st.switching.target }
        }
    } catch {}
    return $r
}

function Get-NMCloseReason($info, $nm, [DateTime]$now, $gctx, [string]$bulk) {
    if ($nm.userClosed.ContainsKey($info.id) -or ($nm.userClosed.ContainsKey('*') -and ($now - [DateTime]$nm.userClosed['*']).TotalSeconds -lt 15)) { return '你在控制台手动关闭' }
    if ($bulk) { return $bulk }
    if ($gctx.switching) { return '正在热切换（' + $gctx.switching + '），换内核会断开已有连接' }
    if ($gctx.lock) { return '守护处于拦截状态：' + $gctx.lock }
    if ($info.chain -match 'REJECT') { return '被规则拒绝：' + $info.rule }
    # 内核在最近 2 分钟里报过与该目标有关的错误
    $key = $info.host
    if ($key) {
        $errs = @($nm.errs.ToArray())
        for ($i = $errs.Count - 1; $i -ge 0; $i--) {
            $e = $errs[$i]
            if (($now - [DateTime]$e.t).TotalSeconds -gt 120) { break }
            if (([string]$e.msg).Contains($key)) { return '内核报错：' + ([string]$e.msg) }
        }
    }
    return '正常结束（程序或服务器关闭了连接）'
}

function Invoke-NMConnLoop($nm, [int]$Gen) {
    # 页面可见时每秒、后台时每 4 秒读一次连接表；计算速度；消失的连接记入「已关闭」并给出原因
    $prev = @{}; $ep = $null; $epAt = [DateTime]::MinValue; $lastLabel = ''; $lastTotals = $null
    while (-not $nm.stop -and $nm.gen -eq $Gen) {
        $now = Get-Date
        try {
            if (-not $ep -or -not $ep.ok -or ($now - $epAt).TotalSeconds -ge 5) { $ep = Get-NMEndpoint; $epAt = $now }
            $req = $null
            while ($nm.closeQ.TryDequeue([ref]$req)) {
                if (-not $ep.ok) { continue }
                try {
                    if ($req -eq '*') { [void](Invoke-NMApi $ep 'DELETE' '/connections') } else { [void](Invoke-NMApi $ep 'DELETE' ('/connections/' + $req)) }
                    $nm.userClosed[$req] = $now
                } catch { $nm.status = '关闭连接失败：' + $_.Exception.Message }
            }
            $data = $null; $err = ''
            if ($ep.ok) { try { $data = Get-NMConnections $ep } catch { $err = $_.Exception.Message; $epAt = [DateTime]::MinValue } } else { $err = $ep.why }
            $label = $(if ($ep.ok) { $ep.label } else { '' })
            $bulk = ''
            if (-not $data) { $bulk = '内核停止或重启（' + $err + '）' }
            elseif ($lastLabel -and $label -ne $lastLabel) { $bulk = ('内核已切换（{0} → {1}），旧内核的连接全部断开' -f $lastLabel, $label) }

            $map = $null; try { $map = [CgSock]::Map() } catch {}
            $rows = New-Object System.Collections.ArrayList
            $seen = @{}; $byProc = @{}
            if ($data) {
                foreach ($c in $data.list) {
                    $id = [string]$c['id']; $md = $c['metadata']
                    $seen[$id] = $true
                    $p = $prev[$id]
                    if (-not $p) {
                        $net = ([string]$md['network']).ToLower()
                        $proc = [string]$md['process']; $procId = 0
                        if (-not $proc) {
                            $sip = [string]$md['sourceIP']
                            if (-not $sip) { $proc = '内核自身' }
                            elseif ($map) {
                                $k = $(if ($net -eq 'udp') { 'u' } else { 't' }) + $sip + ':' + [string]$md['sourcePort']
                                if ($map.ContainsKey($k)) { $procId = $map[$k] }
                                elseif ($net -eq 'udp' -and $map.ContainsKey('u*:' + [string]$md['sourcePort'])) { $procId = $map['u*:' + [string]$md['sourcePort']] }
                                $proc = Get-NMProcName $procId
                                if (-not $proc) { $proc = $(if ($procId) { "PID $procId" } else { '（已退出）' }) }
                            }
                        }
                        $h = [string]$md['host']; if (-not $h) { $h = [string]$md['destinationIP'] }
                        $chains = @($c['chains']); [array]::Reverse($chains)
                        $rule = [string]$c['rule']; if ($c['rulePayload']) { $rule += '(' + [string]$c['rulePayload'] + ')' }
                        $start = $now; try { $start = [DateTime]::Parse([string]$c['start']) } catch {}
                        $p = @{ id = $id; proc = $proc; host = $h; dest = ('{0}:{1}' -f $h, $md['destinationPort'])
                                net = ('{0} · {1}' -f $net.ToUpper(), [string]$md['type']); rule = $rule; chain = ($chains -join ' → ')
                                start = $start; dl = [double]$c['download']; ul = [double]$c['upload']; t = $now; dls = 0.0; uls = 0.0 }
                        $prev[$id] = $p
                    }
                    $dl = [double]$c['download']; $ul = [double]$c['upload']
                    $dt = ($now - $p.t).TotalSeconds
                    if ($dt -gt 0.3) { $p.dls = [Math]::Max(0, ($dl - $p.dl) / $dt); $p.uls = [Math]::Max(0, ($ul - $p.ul) / $dt); $p.t = $now; $p.dl = $dl; $p.ul = $ul }
                    [void]$rows.Add(@{ id = $id; proc = $p.proc; dest = $p.dest; net = $p.net; rule = $p.rule; chain = $p.chain
                        dl = $dl; ul = $ul; dls = $p.dls; uls = $p.uls; start = $p.start.Ticks
                        dlT = (Format-NMBytes $dl); ulT = (Format-NMBytes $ul)
                        dlsT = $(if ($p.dls -ge 1) { (Format-NMBytes $p.dls) + '/s' } else { '-' })
                        ulsT = $(if ($p.uls -ge 1) { (Format-NMBytes $p.uls) + '/s' } else { '-' })
                        durT = (Format-NMSpan ($now - $p.start)) })
                    $a = $byProc[$p.proc]; if (-not $a) { $a = @{ n = 0; s = 0.0 }; $byProc[$p.proc] = $a }
                    $a.n++; $a.s += $p.dls + $p.uls
                }
            }
            # 消失的连接 → 已关闭（带原因）
            $gone = @($prev.Keys | Where-Object { -not $seen.ContainsKey($_) })
            if ($gone.Count -gt 0) {
                $gctx = Get-NMGuardContext
                foreach ($id in $gone) {
                    $p = $prev[$id]; $prev.Remove($id)
                    $reason = Get-NMCloseReason $p $nm $now $gctx $bulk
                    $nm.closedQ.Enqueue(@{ id = $id; proc = $p.proc; dest = $p.dest; rule = $p.rule; chain = $p.chain
                        dl = $p.dl; ul = $p.ul; dlT = (Format-NMBytes $p.dl); ulT = (Format-NMBytes $p.ul)
                        durS = [int]($now - $p.start).TotalSeconds; durT = (Format-NMSpan ($now - $p.start))
                        endTicks = $now.Ticks; endT = $now.ToString('HH:mm:ss'); reason = $reason })
                }
                $tmp = $null; while ($nm.closedQ.Count -gt 1500) { [void]$nm.closedQ.TryDequeue([ref]$tmp) }
            }
            foreach ($k in @($nm.userClosed.Keys)) { if (($now - [DateTime]$nm.userClosed[$k]).TotalSeconds -gt 30) { $nm.userClosed.Remove($k) } }

            # 汇总：谁在用网（按当前速度，其次按连接数）
            $top = @($byProc.GetEnumerator() | Sort-Object @{ e = { $_.Value.s }; d = $true }, @{ e = { $_.Value.n }; d = $true } | Select-Object -First 6 | ForEach-Object {
                '{0} {1} 个{2}' -f $_.Key, $_.Value.n, $(if ($_.Value.s -ge 1024) { '（' + (Format-NMBytes $_.Value.s) + '/s）' } else { '' }) })
            $tot = $null
            if ($data) {
                $sd = 0.0; $su = 0.0
                if ($lastTotals) { $dt = ($now - $lastTotals.t).TotalSeconds; if ($dt -gt 0.3) { $sd = [Math]::Max(0, ($data.down - $lastTotals.down) / $dt); $su = [Math]::Max(0, ($data.up - $lastTotals.up) / $dt) } }
                $lastTotals = @{ down = $data.down; up = $data.up; t = $now }
                $tot = @{ down = $data.down; up = $data.up; sd = $sd; su = $su }
            } else { $lastTotals = $null }
            $nm.conns = $rows.ToArray(); $nm.totals = $tot; $nm.top = ($top -join ' · ')
            $nm.label = $label; $nm.status = $(if ($data) { '' } else { $err })
            $nm.connSeq = [int]$nm.connSeq + 1
            $lastLabel = $label
        } catch { $nm.status = '连接监视出错：' + $_.Exception.Message }
        $wait = $(if ($nm.visible) { 10 } else { 40 })
        for ($i = 0; $i -lt $wait -and -not $nm.wake -and -not $nm.stop -and $nm.gen -eq $Gen; $i++) { Start-Sleep -Milliseconds 100 }
        $nm.wake = $false
    }
}

function Add-NMLog($nm, [string]$lv, [string]$msg) {
    $nm.logSeq = [int64]$nm.logSeq + 1
    $e = @{ seq = [int64]$nm.logSeq; t = Get-Date; lv = $lv; msg = $msg }
    $nm.logQ.Enqueue($e)
    $tmp = $null; while ($nm.logQ.Count -gt 4000) { [void]$nm.logQ.TryDequeue([ref]$tmp) }
    if ($lv -eq 'warning' -or $lv -eq 'error') {
        [void]$nm.errs.Add($e)
        if ($nm.errs.Count -gt 400) { $nm.errs.RemoveRange(0, 100) }
    }
}

function Invoke-NMLogLoop($nm, [int]$Gen) {
    # 订阅内核实时日志（info 及以上）；内核退出 / 切换时流会断开，自动重连到新的内核
    while (-not $nm.stop -and $nm.gen -eq $Gen) {
        $ep = Get-NMEndpoint
        if (-not $ep.ok) {
            if ($nm.logStatus -ne $ep.why) { $nm.logStatus = $ep.why; Add-NMLog $nm 'warning' ('— 没有可连接的内核：' + $ep.why + ' —') }
            $nm.logLabel = ''
            Start-Sleep -Seconds 2; continue
        }
        $r = $null
        try {
            # 内核要等到第一条日志出现才回响应头（空闲时可能很久）：连上就先显示“已连接”
            $nm.logLabel = $ep.label; $nm.logStatus = ''
            $r = Open-NMRequest $ep 'GET' '/logs?level=info' 0
            $nm.curLog = $r
            if ($r.status -ne 200) { throw ('控制接口返回 ' + $r.status) }
            $nm.logStatus = ''; $nm.logLabel = $ep.label
            Add-NMLog $nm 'info' ('— 已连接 ' + $ep.label + ' 的实时日志 —')
            $pend = New-Object System.IO.MemoryStream
            while (-not $nm.stop -and $nm.gen -eq $Gen) {
                $b = Read-NMChunk $r
                if ($null -eq $b) { break }
                $pend.Write($b, 0, $b.Length)
                $all = $pend.ToArray(); $startAt = 0
                for ($i = [Array]::IndexOf($all, [byte]10, 0); $i -ge 0; $i = [Array]::IndexOf($all, [byte]10, $startAt)) {
                    $line = [Text.Encoding]::UTF8.GetString($all, $startAt, $i - $startAt).Trim()
                    $startAt = $i + 1
                    if ($line.StartsWith('{')) { try { $o = $script:NM_Js.DeserializeObject($line); Add-NMLog $nm ([string]$o['type']) ([string]$o['payload']) } catch {} }
                    if ($startAt -ge $all.Length) { break }
                }
                $pend = New-Object System.IO.MemoryStream
                if ($startAt -lt $all.Length) { $pend.Write($all, $startAt, $all.Length - $startAt) }
            }
            Add-NMLog $nm 'warning' ('— ' + $ep.label + ' 的日志流已断开（内核退出、重启或切换）—')
        } catch {
            $m = $_.Exception.Message
            if ($nm.logStatus -ne $m) { Add-NMLog $nm 'warning' ('— 读取内核日志失败：' + $m + ' —') }
            $nm.logStatus = $m
        } finally { $nm.curLog = $null; if ($r) { Close-NMRequest $r } }
        $nm.logLabel = ''
        Start-Sleep -Seconds 2
    }
}
