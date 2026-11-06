# ForceCommand target for claude-ssh: records what the client runs in the session log
# (claude-ssh.ps1 shows it in its window), then runs it with cmd.exe exactly as sshd would.
#
# Record tags written here (one line each: "yyyy-MM-dd HH:mm:ss #<id> TAG text", <id> = this PID):
#   CMD   the command line, with the client IP
#   DEC   the decoded payload of powershell -EncodedCommand
#   IN    text sent on stdin, e.g. a script piped into "[Console]::In.ReadToEnd() | iex"
#   OUT   what the command printed (stdout), as the client got it
#   ERR   what the command printed on stderr
#   FILE  files the command wrote (WriteAllBytes/WriteAllText/Set-Content/Out-File)
#   EXIT  exit code and run time
#   NOTE  anything else worth knowing
# Multi-line text is written as "| line" records under the same tag.
# Keep this file ASCII-only (Windows PowerShell 5.1).
param([string]$Log = '')

$MaxStdinLog  = 1MB     # stdin text kept in the log per command
$MaxOutputLog = 1MB     # stdout text kept in the log per command, and the same for stderr
$MaxFileLog   = 256KB   # file content kept in the log per file

$cmd     = $env:SSH_ORIGINAL_COMMAND
$started = Get-Date
$client  = ''
if ($env:SSH_CLIENT) { $client = ($env:SSH_CLIENT -split ' ')[0] }
$utf8    = New-Object Text.UTF8Encoding($false)
$utf8Strict = New-Object Text.UTF8Encoding($false, $true)
$oem = $utf8
try { $oem = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { }

function Write-Log {
    param([string]$Tag, [string[]]$Lines)
    if (-not $Log -or -not $Lines) { return }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $sb = New-Object Text.StringBuilder
    foreach ($l in $Lines) {
        $one = "$l" -replace "[\r\n]+", ' '
        [void]$sb.Append(('{0} #{1} {2,-4} {3}' -f $stamp, $PID, $Tag, $one)).Append("`r`n")
    }
    $text = $sb.ToString()
    # Several sessions append to the same file: retry while another writer holds it.
    for ($i = 0; $i -lt 100; $i++) {
        try { [IO.File]::AppendAllText($Log, $text, $utf8); return } catch { Start-Sleep -Milliseconds 30 }
    }
}

# Multi-line text -> "| line" records.
function ConvertTo-Body {
    param([string]$Text)
    $t = $Text -replace "`r`n", "`n"
    if ($t.EndsWith("`n")) { $t = $t.Substring(0, $t.Length - 1) }
    $parts = $t -split "`n"
    for ($i = 0; $i -lt $parts.Length; $i++) { $parts[$i] = '| ' + $parts[$i] }
    return $parts
}

# Bytes a program printed or got -> text: UTF-8 if they are valid UTF-8, else the OEM code page
# (what cmd.exe and most console programs print in).
function ConvertFrom-Bytes {
    param([byte[]]$Bytes, [int]$Count)
    try { return $utf8Strict.GetString($Bytes, 0, $Count) } catch { return $oem.GetString($Bytes, 0, $Count) }
}

# Header plus content (text) or size and hash (binary) of a file the command wrote.
function Get-FileRecord {
    param([IO.FileInfo]$File)
    $len  = $File.Length
    $head = '{0} ({1} bytes)' -f $File.FullName, $len
    if ($len -eq 0) { return @($head) }
    $n = [int][Math]::Min($len, $MaxFileLog)
    $bytes = New-Object byte[] $n
    $got = 0
    $fs = [IO.File]::Open($File.FullName, 'Open', 'Read', 'ReadWrite, Delete')
    try {
        while ($got -lt $n) { $r = $fs.Read($bytes, $got, $n - $got); if ($r -le 0) { break }; $got += $r }
    } finally { $fs.Dispose() }
    $enc = $null; $skip = 0
    if ($got -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $enc = [Text.Encoding]::Unicode; $skip = 2 }
    elseif ($got -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $enc = [Text.Encoding]::BigEndianUnicode; $skip = 2 }
    elseif ($got -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $enc = $utf8; $skip = 3 }
    elseif ([Array]::IndexOf($bytes, [byte]0, 0, $got) -lt 0) { $enc = $utf8 }
    if (-not $enc) {
        $hash = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.Substring(0, 16)
        return @("$head, binary, sha256 $hash...")
    }
    $out = @($head) + (ConvertTo-Body ($enc.GetString($bytes, $skip, $got - $skip)))
    if ($len -gt $got) { $out += ('| ... ({0} more bytes not shown)' -f ($len - $got)) }
    return $out
}

# ---------------------------------------------------------------- pumps
# A pump copies one stream as it arrives (client stdin -> command, command stdout/stderr ->
# client) and keeps the text for the log. Reading and writing are separate and asynchronous,
# with a queue in between: a pump reads ahead into memory (up to $MaxQueue) while the other
# side is busy. That matters: sshd does not read the command's output while it waits for us
# to take its stdin, so if taking stdin waited for the command, all three would wait for ever.
$MaxQueue = 64MB

function New-Pump {
    param([string]$Tag, [string]$What, [IO.Stream]$Src, [IO.Stream]$Dst, [long]$Max, [bool]$CloseDst)
    $pp = @{ Tag = $Tag; What = $What; Src = $Src; Dst = $Dst; DstOk = $true; CloseDst = $CloseDst; Max = $Max
             Buf = (New-Object byte[] 65536); ReadTask = $null; SrcDone = $false
             Queue = (New-Object Collections.Queue); Queued = 0L; WriteTask = $null; WritePhase = ''; Writing = 0
             Done = $false
             Pending = (New-Object IO.MemoryStream); Text = (New-Object Text.StringBuilder)
             Logged = 0L; Total = 0L; Binary = $false; Last = [DateTime]::UtcNow }
    Start-PumpRead $pp
    return $pp
}

function Start-PumpRead {
    param($pp)
    try { $pp.ReadTask = $pp.Src.ReadAsync($pp.Buf, 0, $pp.Buf.Length) } catch { $pp.ReadTask = $null; $pp.SrcDone = $true }
}

# Stop sending (the other side is gone: client disconnected, command ended). Reading and
# logging go on.
function Close-PumpOutput {
    param($pp)
    $pp.DstOk = $false; $pp.WriteTask = $null; $pp.Queue.Clear(); $pp.Queued = 0L; $pp.Writing = 0
}

# Move the pump on: take what was read, finish a write, start the next write and read.
function Step-Pump {
    param($pp)
    $t = $pp.ReadTask
    if ($t -and $t.IsCompleted) {
        $pp.ReadTask = $null
        $n = 0
        try { $n = $t.Result } catch { $n = 0 }   # a failed read = end of the stream
        if ($n -le 0) {
            $pp.SrcDone = $true
        } else {
            $pp.Total += $n
            if (-not $pp.Binary -and [Array]::IndexOf($pp.Buf, [byte]0, 0, $n) -ge 0) { $pp.Binary = $true }
            if (-not $pp.Binary) {
                $room = $pp.Max - $pp.Logged - $pp.Pending.Length
                if ($room -gt 0) { $pp.Pending.Write($pp.Buf, 0, [int][Math]::Min($n, $room)) }
            }
            if ($pp.DstOk) {
                $chunk = New-Object byte[] $n
                [Array]::Copy($pp.Buf, $chunk, $n)
                $pp.Queue.Enqueue($chunk); $pp.Queued += $n
            }
        }
    }
    $t = $pp.WriteTask
    if ($t -and $t.IsCompleted) {
        $pp.WriteTask = $null
        if ($t.IsFaulted) { Close-PumpOutput $pp }
        elseif ($pp.WritePhase -eq 'write') {
            try { $pp.WriteTask = $pp.Dst.FlushAsync(); $pp.WritePhase = 'flush' } catch { Close-PumpOutput $pp }
        }
        if (-not $pp.WriteTask) { $pp.Queued -= $pp.Writing; $pp.Writing = 0 }
    }
    if ($pp.DstOk -and -not $pp.WriteTask -and $pp.Queue.Count -gt 0) {
        $chunk = [byte[]]$pp.Queue.Dequeue()
        $pp.Writing = $chunk.Length
        try { $pp.WriteTask = $pp.Dst.WriteAsync($chunk, 0, $chunk.Length); $pp.WritePhase = 'write' } catch { Close-PumpOutput $pp }
    }
    if (-not $pp.ReadTask -and -not $pp.SrcDone -and $pp.Queued -lt $MaxQueue) { Start-PumpRead $pp }
    if ($pp.SrcDone -and -not $pp.WriteTask -and $pp.Queue.Count -eq 0 -and -not $pp.Done) {
        $pp.Done = $true
        if ($pp.CloseDst) { try { $pp.Dst.Close() } catch { } }   # end of stdin: let the command see it
    }
}

# Log the pump's pending bytes: everything, or (while streaming) up to the last full line.
function Write-PumpLog {
    param($pp, [bool]$All)
    if ($pp.Pending.Length -eq 0) { return }
    $bytes = $pp.Pending.ToArray()
    $cut = $bytes.Length
    if (-not $All) {
        $lf = [Array]::LastIndexOf($bytes, [byte]10)
        if ($lf -lt 0) { return }
        $cut = $lf + 1
    }
    $text = ConvertFrom-Bytes $bytes $cut
    [void]$pp.Text.Append($text)
    Write-Log $pp.Tag (ConvertTo-Body $text)
    $pp.Logged += $cut
    $pp.Pending.SetLength(0)
    if ($cut -lt $bytes.Length) { $pp.Pending.Write($bytes, $cut, $bytes.Length - $cut) }
    $pp.Last = [DateTime]::UtcNow
}

function Complete-PumpLog {
    param($pp)
    if ($pp.Binary) {
        Write-Log $pp.Tag @(('(binary data on {0}, {1} bytes, not shown)' -f $pp.What, $pp.Total))
        return
    }
    Write-PumpLog $pp $true
    if ($pp.Total -gt $pp.Logged) {
        Write-Log $pp.Tag @(('({0}: {1} bytes in total, the first {2} are shown)' -f $pp.What, $pp.Total, $pp.Logged))
    }
}

# ---------------------------------------------------------------- what is being run
$shown = '(interactive shell)'
if ($cmd) { $shown = $cmd }
$cmdLines = @(($shown -replace "`r`n", "`n") -split "`n")
if ($cmdLines.Count -le 1) { Write-Log 'CMD' @("[$client] $shown") }
else { Write-Log 'CMD' (@("[$client] (multi-line command)") + ($cmdLines | ForEach-Object { '| ' + $_ })) }

# powershell -EncodedCommand <base64 UTF-16>: show the payload as text.
# Accepts -e, -ec and any prefix of -EncodedCommand; skips -ExecutionPolicy and friends.
$decoded = ''
if ($cmd -and $cmd -match '(?i)\b(?:powershell|pwsh)(?:\.exe)?\b') {
    foreach ($m in [regex]::Matches($cmd, '(?i)\s-(e[a-z]*)\s+([A-Za-z0-9+/=]{8,})')) {
        $opt = $m.Groups[1].Value.ToLowerInvariant()
        if ($opt -eq 'e' -or $opt -eq 'ec' -or ($opt.Length -ge 3 -and 'encodedcommand'.StartsWith($opt))) {
            try {
                $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($m.Groups[2].Value))
                Write-Log 'DEC' (ConvertTo-Body $decoded)
            } catch { $decoded = '' }
            break
        }
    }
}

# ---------------------------------------------------------------- run it
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = Join-Path $env:WINDIR 'System32\cmd.exe'
if ($cmd) { $psi.Arguments = '/c ' + $cmd }
$psi.UseShellExecute = $false
# "ssh host command": stdin, stdout and stderr are pipes. Pass each through a pump, so the
# command gets exactly the same bytes and the log gets a copy. A console session (ssh -t)
# keeps its console: nothing is copied, its processes are still shown.
$redirIn = $false; $redirOut = $false; $redirErr = $false
try { $redirIn  = [Console]::IsInputRedirected }  catch { }
try { $redirOut = [Console]::IsOutputRedirected } catch { }
try { $redirErr = [Console]::IsErrorRedirected }  catch { }
$psi.RedirectStandardInput  = $redirIn
$psi.RedirectStandardOutput = $redirOut
$psi.RedirectStandardError  = $redirErr
$p = [Diagnostics.Process]::Start($psi)

$pumps = New-Object Collections.ArrayList
$inPump = $null
if ($redirIn) {
    $inPump = New-Pump 'IN' 'stdin' ([Console]::OpenStandardInput()) $p.StandardInput.BaseStream $MaxStdinLog $true
    [void]$pumps.Add($inPump)
}
if ($redirOut) { [void]$pumps.Add((New-Pump 'OUT' 'stdout' $p.StandardOutput.BaseStream ([Console]::OpenStandardOutput()) $MaxOutputLog $false)) }
if ($redirErr) { [void]$pumps.Add((New-Pump 'ERR' 'stderr' $p.StandardError.BaseStream ([Console]::OpenStandardError()) $MaxOutputLog $false)) }
if (-not ($redirIn -or $redirOut -or $redirErr)) {
    Write-Log 'NOTE' @('(console session: keystrokes and output are not logged, started programs are shown as PROC)')
}

while ($true) {
    $exited = $p.HasExited
    $tasks = New-Object Collections.Generic.List[Threading.Tasks.Task]
    $live = 0
    foreach ($pp in $pumps) {
        if ($pp.Tag -eq 'IN' -and $exited -and -not $pp.Done) {   # nobody reads stdin any more
            Close-PumpOutput $pp; $pp.ReadTask = $null; $pp.Done = $true
        }
        if ($pp.Done) { continue }
        $live++
        if ($pp.ReadTask)  { $tasks.Add($pp.ReadTask) }
        if ($pp.WriteTask) { $tasks.Add($pp.WriteTask) }
    }
    if ($live -eq 0) { break }   # output closed (and stdin, or the command ended)
    if ($tasks.Count) { try { [void][Threading.Tasks.Task]::WaitAny($tasks.ToArray(), 200) } catch { } }
    else { Start-Sleep -Milliseconds 50 }
    foreach ($pp in $pumps) { if (-not $pp.Done) { Step-Pump $pp } }
    foreach ($pp in $pumps) {
        if (-not $pp.Binary -and $pp.Pending.Length -gt 0 -and
            ($pp.Pending.Length -ge 64KB -or ([DateTime]::UtcNow - $pp.Last).TotalSeconds -ge 2)) { Write-PumpLog $pp $false }
    }
}
$p.WaitForExit()
foreach ($pp in $pumps) { Complete-PumpLog $pp }

# ---------------------------------------------------------------- files it wrote
try {
    $stdinText = ''
    if ($inPump) { $stdinText = $inPump.Text.ToString() }
    $scan  = "$cmd`n$decoded`n$stdinText"
    $paths = New-Object Collections.Generic.List[string]
    $patterns = @(
        '(?i)\b(?:WriteAllBytes|WriteAllText|WriteAllLines)\(\s*[''"]([^''"]+)[''"]',
        '(?i)\b(?:Set-Content|Out-File)\b[^|;\r\n]*?-(?:Path|FilePath|LiteralPath)\s+[''"]([^''"]+)[''"]',
        '(?i)\b(?:Set-Content|Out-File)\s+[''"]([^''"]+)[''"]'
    )
    foreach ($rx in $patterns) {
        foreach ($m in [regex]::Matches($scan, $rx)) {
            $path = $m.Groups[1].Value
            # *.b64 = staging chunks of an upload; the decoded target file is shown instead.
            if ($path -notmatch '(?i)\.b64$' -and -not $paths.Contains($path)) { $paths.Add($path) }
        }
    }
    foreach ($path in $paths) {
        try {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $fi = Get-Item -LiteralPath $path
            if ($fi.LastWriteTime -lt $started.AddSeconds(-2)) { continue }   # not written by this command
            Write-Log 'FILE' (Get-FileRecord $fi)
        } catch { }
    }
} catch { }

$ended = Get-Date
try { $ended = $p.ExitTime } catch { }
Write-Log 'EXIT' @(('{0} ({1:0.0} s)' -f $p.ExitCode, ($ended - $started).TotalSeconds))
exit $p.ExitCode
