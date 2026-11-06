# ForceCommand target for claude-ssh: records what the client runs in the session log
# (claude-ssh.ps1 shows it in its window), then runs it with cmd.exe exactly as sshd would.
#
# Record tags written here (one line each: "HH:mm:ss #<id> TAG text", <id> = this PID):
#   CMD   the command line, with the client IP
#   DEC   the decoded payload of powershell -EncodedCommand
#   IN    text sent on stdin, e.g. a script piped into "[Console]::In.ReadToEnd() | iex"
#   FILE  files the command wrote (WriteAllBytes/WriteAllText/Set-Content/Out-File)
#   EXIT  exit code and run time
#   NOTE  anything else worth knowing
# Multi-line text is written as "| line" records under the same tag.
# Keep this file ASCII-only (Windows PowerShell 5.1).
param([string]$Log = '')

$MaxStdinLog = 1MB     # stdin text kept in the log per command
$MaxFileLog  = 256KB   # file content kept in the log per file

$cmd     = $env:SSH_ORIGINAL_COMMAND
$started = Get-Date
$client  = ''
if ($env:SSH_CLIENT) { $client = ($env:SSH_CLIENT -split ' ')[0] }
$utf8    = New-Object Text.UTF8Encoding($false)

function Write-Log {
    param([string]$Tag, [string[]]$Lines)
    if (-not $Log -or -not $Lines) { return }
    $stamp = Get-Date -Format 'HH:mm:ss'
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
    return @($t -split "`n" | ForEach-Object { '| ' + $_ })
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
# stdin is a pipe for "ssh host command": copy it to the child AND to the log as it arrives.
# A console session (ssh -t) keeps its console: it is not copied, its processes are still shown.
$tee = $false
try { $tee = [Console]::IsInputRedirected } catch { }
$psi.RedirectStandardInput = $tee
$p = [Diagnostics.Process]::Start($psi)

$stdinText = New-Object Text.StringBuilder
if ($tee) {
    $stdin   = [Console]::OpenStandardInput()
    $childIn = $p.StandardInput.BaseStream
    $childOk = $true
    $pending = New-Object IO.MemoryStream
    $state   = @{ Logged = 0L; Total = 0L; Binary = $false; Last = [DateTime]::UtcNow }

    # Log pending stdin bytes: everything, or (while streaming) up to the last full line.
    function Write-PendingStdin {
        param([bool]$All)
        if ($pending.Length -eq 0) { return }
        $bytes = $pending.ToArray()
        $cut = $bytes.Length
        if (-not $All) {
            $lf = [Array]::LastIndexOf($bytes, [byte]10)
            if ($lf -lt 0) { return }
            $cut = $lf + 1
        }
        $text = $utf8.GetString($bytes, 0, $cut)
        [void]$stdinText.Append($text)
        Write-Log 'IN' (ConvertTo-Body $text)
        $state.Logged += $cut
        $pending.SetLength(0)
        if ($cut -lt $bytes.Length) { $pending.Write($bytes, $cut, $bytes.Length - $cut) }
        $state.Last = [DateTime]::UtcNow
    }

    $buf  = New-Object byte[] 65536
    $task = $stdin.ReadAsync($buf, 0, $buf.Length)
    while ($true) {
        $done = $false
        try { $done = $task.Wait(200) } catch { $task = $null }   # a failed read = end of input
        if ($task -and $done) {
            $n = $task.Result
            if ($n -le 0) {
                $task = $null
            } else {
                if ($childOk) { try { $childIn.Write($buf, 0, $n); $childIn.Flush() } catch { $childOk = $false } }
                $state.Total += $n
                if (-not $state.Binary -and [Array]::IndexOf($buf, [byte]0, 0, $n) -ge 0) { $state.Binary = $true }
                if (-not $state.Binary) {
                    $room = $MaxStdinLog - $state.Logged - $pending.Length
                    if ($room -gt 0) { $pending.Write($buf, 0, [int][Math]::Min($n, $room)) }
                }
                $task = $stdin.ReadAsync($buf, 0, $buf.Length)
            }
        }
        if (-not $task -or $p.HasExited) { break }
        if (-not $state.Binary -and $pending.Length -gt 0 -and
            ($pending.Length -ge 64KB -or ([DateTime]::UtcNow - $state.Last).TotalSeconds -ge 2)) { Write-PendingStdin $false }
    }
    if (-not $state.Binary) { Write-PendingStdin $true }
    if ($state.Binary) { Write-Log 'IN' @(('(binary data on stdin, {0} bytes, not shown)' -f $state.Total)) }
    elseif ($state.Total -gt $state.Logged) { Write-Log 'IN' @(('(stdin: {0} bytes in total, the first {1} are shown)' -f $state.Total, $state.Logged)) }
    if (-not $task) { try { $childIn.Close() } catch { } }   # end of input: let the child see it
} else {
    Write-Log 'NOTE' @('(console session: keystrokes are not logged, started programs are shown as PROC)')
}
$p.WaitForExit()

# ---------------------------------------------------------------- files it wrote
try {
    $scan  = "$cmd`n$decoded`n$($stdinText.ToString())"
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

Write-Log 'EXIT' @(('{0} ({1:0.0} s)' -f $p.ExitCode, ((Get-Date) - $started).TotalSeconds))
exit $p.ExitCode
