# Claude SSH session: runs sshd in THIS window.
# Close the window, press Ctrl+C, or let the time run out = SSH is gone.
#
#   claude-ssh.bat              (2 hours)
#   claude-ssh.bat -Duration 4h
#
# Nothing is installed and no Windows service is used: portable, Microsoft-signed
# OpenSSH from .\OpenSSH-Win64 runs as YOUR account, so only your account can log in,
# only with the allowed keys, only from AllowIp. Everything the client does is shown here:
# commands, scripts sent on stdin, files they write and every process they start.
#
# Settings, keys and logs live in %LOCALAPPDATA%\ClaudeSSH (only you, SYSTEM and
# Administrators have access), never next to this script and never in git.
# Keep this file ASCII-only (Windows PowerShell 5.1).

# Defaults come from claude-ssh.config in the data folder; parameters override them.
param(
    [string]$Duration = '',
    [int]$Port = 0,
    [string]$AllowIp = '',
    [string]$ListenAddress = '0.0.0.0',
    [string]$DataDir = '',
    [switch]$NoFirewall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Root     = $PSScriptRoot
$Bin      = Join-Path $Root 'OpenSSH-Win64'
$Wrapper  = Join-Path $Root 'cmdlog.ps1'
$DataDirGiven = $PSBoundParameters.ContainsKey('DataDir')
if (-not $DataDir) { $DataDir = Join-Path $env:LOCALAPPDATA 'ClaudeSSH' }
$DataDir  = [IO.Path]::GetFullPath($DataDir)
$Config   = Join-Path $DataDir 'claude-ssh.config'
$KeysList = Join-Path $DataDir 'allowed_keys.txt'
$KeyDir   = Join-Path $DataDir 'hostkey'   # kept between runs: stable fingerprint
$LogDir   = Join-Path $DataDir 'logs'      # one log per session, kept
$Work     = Join-Path $DataDir 'session'   # wiped at start and at stop
$RuleName = 'Claude-SSH-session'
$ProcSource    = 'ClaudeSshProc'
$MaxBlockLines = 40    # console only: lines shown per script/file block (the log has all)
$MaxLineChars  = 400   # console only: characters shown per line

function Say {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text) -ForegroundColor $Color
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-Minutes {
    param([string]$Text)
    $d = "$Text".Trim().ToLowerInvariant()
    if ($d -match '^\d+$') { return [int]$d * 60 }
    if ($d -ne '' -and $d -match '^(?:(\d+)h)?(?:(\d+)m(?:in)?)?$') {
        $h = 0; $m = 0
        if ($Matches[1]) { $h = [int]$Matches[1] }
        if ($Matches[2]) { $m = [int]$Matches[2] }
        return $h * 60 + $m
    }
    throw "Bad duration '$Text'. Use e.g. 2h, 90m, 1h30m."
}

# Owner-only file: current user + SYSTEM + Administrators (what sshd requires for keys).
function Set-PrivateAcl {
    param([string]$Path)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $Path /inheritance:r /grant:r "*${sid}:F" '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $Path" }
}

# Same for a folder, inherited by everything created in it.
function Set-PrivateDirAcl {
    param([string]$Path)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $Path /inheritance:r /grant:r "*${sid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $Path" }
}

# Groups other than you that can change a path. Whoever can change the files of this
# tool can run code as you WITH administrator rights (the window runs elevated).
function Get-BroadWriters {
    param([string]$Path)
    $broad = @{ 'S-1-1-0' = 'Everyone'; 'S-1-5-11' = 'Authenticated Users'; 'S-1-5-32-545' = 'Users';
                'S-1-5-4' = 'INTERACTIVE'; 'S-1-5-32-546' = 'Guests' }
    # WriteData, AppendData, DeleteChild, Delete, WRITE_DAC, WRITE_OWNER, GENERIC_ALL, GENERIC_WRITE
    $mask = 0x2 -bor 0x4 -bor 0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
    $found = @()
    try { $acl = Get-Acl -LiteralPath $Path } catch { return $found }
    foreach ($ace in $acl.Access) {
        if ("$($ace.AccessControlType)" -ne 'Allow') { continue }
        try { $sid = $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { continue }
        if (-not $broad.ContainsKey($sid)) { continue }
        if (([int64]$ace.FileSystemRights -band $mask) -ne 0) { $found += $broad[$sid] }
    }
    return @($found | Select-Object -Unique)
}

# Our own sshd processes only (by path), never a system sshd.
function Stop-OurSshd {
    $prefix = $Bin.TrimEnd('\') + '\'
    Get-Process -Name 'sshd', 'sshd-session', 'sshd-auth' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

# Put this PowerShell (and so everything it starts: sshd, sessions, Claude's commands) into
# a Windows job object that is killed when this process dies - e.g. the window is closed.
function Enable-KillOnClose {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ClaudeSshJob {
    [StructLayout(LayoutKind.Sequential)] struct BasicLimit {
        public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit;
        public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass; }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong a, b, c, d, e, f; }
    [StructLayout(LayoutKind.Sequential)] struct ExtLimit {
        public BasicLimit Basic; public IoCounters Io; public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit; public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed; }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateJobObject(IntPtr attr, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtLimit info, uint len);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    static IntPtr handle;   // kept open for the life of this process
    public static void Enable() {
        handle = CreateJobObject(IntPtr.Zero, null);
        if (handle == IntPtr.Zero) throw new Exception("CreateJobObject failed: " + Marshal.GetLastWin32Error());
        ExtLimit info = new ExtLimit();
        info.Basic.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if (!SetInformationJobObject(handle, 9, ref info, (uint)Marshal.SizeOf(typeof(ExtLimit))))
            throw new Exception("SetInformationJobObject failed: " + Marshal.GetLastWin32Error());
        if (!AssignProcessToJobObject(handle, GetCurrentProcess()))
            throw new Exception("AssignProcessToJobObject failed: " + Marshal.GetLastWin32Error());
    }
}
'@
    [ClaudeSshJob]::Enable()
}

# Everything started from this window (sshd, sessions, Claude's commands) - by process tree.
function Stop-Descendants {
    $all = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)
    $found = New-Object System.Collections.Generic.List[int]
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($PID)
    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        foreach ($p in $all) {
            $id = [int]$p.ProcessId
            if ($p.ParentProcessId -eq $parent -and $id -ne $PID -and -not $found.Contains($id)) {
                $found.Add($id); $queue.Enqueue($id)
            }
        }
    }
    foreach ($id in $found) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
}

function Remove-OurFirewallRule {
    if (-not $NoFirewall) { Remove-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue }
}

# "Name = value" lines; a name may repeat (AllowIp). Returns @{ name = @(values) }.
function Read-SessionConfig {
    param([string]$Path)
    $result = @{}
    if (-not (Test-Path $Path)) { return $result }
    foreach ($line in Get-Content -Path $Path) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        if ($t -notmatch '^([A-Za-z]+)\s*=\s*(.*)$') { throw "Bad line in ${Path}: $line" }
        $name = $Matches[1].ToLowerInvariant()
        if (-not $result.ContainsKey($name)) { $result[$name] = @() }
        $result[$name] += $Matches[2].Trim()
    }
    return $result
}

function Read-AllowedKeys {
    if (-not (Test-Path $KeysList)) { return @() }
    $keys = @(Get-Content -Path $KeysList | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') })
    foreach ($k in $keys) {
        if ($k -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-\S+|sk-\S+) [A-Za-z0-9+/=]+') { throw "Not a public key line in ${KeysList}: $k" }
    }
    return $keys
}

# ---------------------------------------------------------------- data folder

# Move a file/folder of the old layout (next to the script) into the data folder.
function Move-Legacy {
    param([string]$From, [string]$To)
    try {
        Move-Item -LiteralPath $From -Destination $To -ErrorAction Stop
    } catch {
        Copy-Item -LiteralPath $From -Destination $To -Recurse -Force
        Say "Could not move $From (copied instead). Delete it by hand: it should not stay next to the script." Red
    }
}

# Create %LOCALAPPDATA%\ClaudeSSH (owner-only), move old files into it, add templates.
function Initialize-DataDir {
    if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
    Set-PrivateDirAcl $DataDir
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

    $moved = @()
    foreach ($name in 'claude-ssh.config', 'allowed_keys.txt') {
        $old = Join-Path $Root $name
        if ((Test-Path $old) -and -not (Test-Path (Join-Path $DataDir $name))) {
            Move-Legacy $old (Join-Path $DataDir $name); $moved += $name
        }
    }
    $oldKeyDir = Join-Path $Root 'hostkey'
    if ((Test-Path (Join-Path $oldKeyDir 'ssh_host_ed25519_key')) -and
        -not (Test-Path (Join-Path $KeyDir 'ssh_host_ed25519_key'))) {
        if (Test-Path $KeyDir) { Remove-Item -LiteralPath $KeyDir -Recurse -Force }
        Move-Legacy $oldKeyDir $KeyDir; $moved += 'hostkey\ (same host key fingerprint)'
    }
    $oldLogs = @(Get-ChildItem -LiteralPath $Root -Filter 'last-session-commands-*.log' -File -ErrorAction SilentlyContinue)
    foreach ($f in $oldLogs) { Move-Legacy $f.FullName (Join-Path $LogDir $f.Name) }
    if ($oldLogs.Count) { $moved += ('{0} old session log(s)' -f $oldLogs.Count) }
    if ($moved.Count) { Say ('Moved from {0} to {1}: {2}' -f $Root, $DataDir, ($moved -join ', ')) Green }

    # Templates on the first run. AllowIp lines stay commented out: the examples are not real.
    if (-not (Test-Path $Config)) {
        $example = Join-Path $Root 'claude-ssh.config.example'
        $lines = @('Duration = 2h', 'Port = 2222', '# AllowIp = 203.0.113.10')
        if (Test-Path $example) { $lines = @(Get-Content -Path $example | ForEach-Object { $_ -replace '^(\s*AllowIp\s*=)', '# $1' }) }
        Set-Content -Path $Config -Value $lines -Encoding Ascii
    }
    if (-not (Test-Path $KeysList)) {
        $example = Join-Path $Root 'allowed_keys.example.txt'
        $lines = @('# Public keys allowed to log in, one per line.')
        if (Test-Path $example) { $lines = @(Get-Content -Path $example) }
        Set-Content -Path $KeysList -Value $lines -Encoding Ascii
    }
}

# ---------------------------------------------------------------- session log
# One line per record: "HH:mm:ss #<id> TAG text". cmdlog.ps1 (one per command, <id> = its
# PID) and this window (PROC records) append to the same file; the window prints new lines.

function Write-LogRecord {
    param([string]$Id, [string]$Tag, [string[]]$Lines)
    if (-not $script:SessionLog -or -not $Lines) { return }
    $stamp = Get-Date -Format 'HH:mm:ss'
    $sb = New-Object Text.StringBuilder
    foreach ($l in $Lines) {
        $one = "$l" -replace "[\r\n]+", ' '
        [void]$sb.Append(('{0} #{1} {2,-4} {3}' -f $stamp, $Id, $Tag, $one)).Append("`r`n")
    }
    $enc = New-Object Text.UTF8Encoding($false)
    for ($i = 0; $i -lt 100; $i++) {
        try { [IO.File]::AppendAllText($script:SessionLog, $sb.ToString(), $enc); return } catch { Start-Sleep -Milliseconds 30 }
    }
}

# New complete lines since the last call (reads only the new part of the file).
function Read-NewLogLines {
    $fs = $null
    try { $fs = [IO.File]::Open($script:SessionLog, 'Open', 'Read', 'ReadWrite, Delete') } catch { return @() }
    try {
        $len = $fs.Length
        if ($len -le $script:LogPos) { return @() }
        [void]$fs.Seek($script:LogPos, 'Begin')
        $count = [int][Math]::Min($len - $script:LogPos, 8MB)
        $buf = New-Object byte[] $count
        $n = $fs.Read($buf, 0, $count)
        if ($n -le 0) { return @() }
        $last = [Array]::LastIndexOf($buf, [byte]10, $n - 1)
        if ($last -lt 0) { return @() }   # a line is still being written
        $script:LogPos += $last + 1
        $text = [Text.Encoding]::UTF8.GetString($buf, 0, $last + 1)
        return @($text -split "`r?`n" | Where-Object { $_ -ne '' })
    } finally { $fs.Dispose() }
}

$B64Evaluator = [Text.RegularExpressions.MatchEvaluator] { param($m) '<base64, {0} chars>' -f $m.Value.Length }
function Format-ForConsole {
    param([string]$Text)
    $s = [regex]::Replace($Text, '[A-Za-z0-9+/]{120,}={0,2}', $B64Evaluator)
    if ($s.Length -gt $MaxLineChars) { $s = $s.Substring(0, $MaxLineChars) + (' ... (+{0} chars)' -f ($s.Length - $MaxLineChars)) }
    return $s
}

$TagColors = @{ CMD = 'Yellow'; DEC = 'DarkYellow'; IN = 'Cyan'; FILE = 'Green'; PROC = 'Magenta'; EXIT = 'DarkGray'; NOTE = 'DarkGray' }
$script:BlockKey = ''; $script:BlockCount = 0; $script:BlockHidden = 0

function Complete-Block {
    if ($script:BlockHidden -gt 0) {
        Write-Host ('           ... {0} more line(s): see the session log' -f $script:BlockHidden) -ForegroundColor DarkGray
        $script:BlockHidden = 0
    }
}

function Show-LogLine {
    param([string]$Line)
    if ($Line -notmatch '^(\d\d:\d\d:\d\d) #(\d+) (\w+)\s+(.*)$') { Complete-Block; Write-Host $Line; return }
    $time = $Matches[1]; $id = $Matches[2]; $tag = $Matches[3]; $text = $Matches[4]
    if ($id -eq '0' -and $tag -ne 'PROC') { return }   # this window's own notes: already printed
    # A block = a header line plus its "| ..." lines: show the first lines only.
    $key = "$id/$tag"
    if (-not $text.StartsWith('|') -or $key -ne $script:BlockKey) {
        Complete-Block; $script:BlockKey = $key; $script:BlockCount = 0
    }
    $script:BlockCount++
    if ($script:BlockCount -gt $MaxBlockLines) { $script:BlockHidden++; return }
    $color = 'Gray'
    if ($TagColors.ContainsKey($tag)) { $color = $TagColors[$tag] }
    if ($tag -eq 'EXIT' -and $text -notmatch '^0 ') { $color = 'Red' }
    Write-Host ('  {0} #{1,-5} {2,-4} {3}' -f $time, $id, $tag, (Format-ForConsole $text)) -ForegroundColor $color
}

# ---------------------------------------------------------------- process watch
# Every process started under our sshd is put in a tree. Shown (as PROC records):
# what Claude's commands start. Hidden: sshd itself, cmdlog.ps1, its cmd.exe /c, the
# command itself (it is already shown as CMD) and conhost.exe.
$script:ProcMode = ''
$script:ProcTree = @{}
$script:ProcWait = New-Object System.Collections.ArrayList

function Start-ProcWatch {
    try {   # every process start, but only for administrators
        Register-CimIndicationEvent -ClassName Win32_ProcessStartTrace -SourceIdentifier $ProcSource -ErrorAction Stop | Out-Null
        $script:ProcMode = 'trace'
    } catch {
        try {   # polled once a second: works for everyone, misses very short processes
            Register-CimIndicationEvent -Query "SELECT * FROM __InstanceCreationEvent WITHIN 1 WHERE TargetInstance ISA 'Win32_Process'" `
                -SourceIdentifier $ProcSource -ErrorAction Stop | Out-Null
            $script:ProcMode = 'poll'
        } catch { $script:ProcMode = '' }
    }
}

function Stop-ProcWatch {
    Unregister-Event -SourceIdentifier $ProcSource -ErrorAction SilentlyContinue
    Remove-Event -SourceIdentifier $ProcSource -ErrorAction SilentlyContinue
}

function Get-ProcCmdLine {
    param([int]$ProcId)
    try {
        $w = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcId" -ErrorAction Stop
        if ($w -and $w.CommandLine) { return [string]$w.CommandLine }
    } catch { }
    return $null
}

# Returns $false while the parent is unknown (not ours, or its event has not come yet).
function Add-ProcEvent {
    param($Item)
    $parent = $script:ProcTree[$Item.Ppid]
    if ($null -eq $parent) { return $false }
    $cl = $Item.Cmd
    if (-not $cl) { $cl = Get-ProcCmdLine $Item.Pid }
    $name = "$($Item.Name)".ToLowerInvariant()
    $node = @{ Role = 'child'; Owner = $parent.Owner; Depth = $parent.Depth + 1; Interactive = $parent.Interactive }
    if ($parent.Role -eq 'sshd' -or $parent.Role -eq 'plumb') {
        $node.Depth = 1
        if (($name -eq 'powershell.exe' -or $name -eq 'pwsh.exe') -and "$cl" -like '*cmdlog.ps1*') {
            $node.Role = 'wrapper'; $node.Owner = $Item.Pid; $node.Depth = 0
        } elseif ($name -like 'sshd*' -or $name -like 'ssh-*' -or $name -eq 'cmd.exe' -or "$cl" -like '*cmdlog.ps1*') {
            $node.Role = 'plumb'; $node.Depth = 0
        }
    } elseif ($parent.Role -eq 'wrapper') {
        $node.Role = 'shell'; $node.Depth = 0
        $node.Interactive = ("$cl" -notmatch '(?i)(^|\s)/c(\s|$)')
    } elseif ($parent.Role -eq 'shell') {
        $node.Role = 'cmd'; $node.Depth = 0
    }
    if ($name -eq 'conhost.exe') { $node.Role = 'plumb' }
    $script:ProcTree[$Item.Pid] = $node

    if ($node.Role -eq 'child' -or ($node.Role -eq 'cmd' -and $node.Interactive)) {
        $text = $cl
        if (-not $text) { $text = '{0} (ended before its command line could be read)' -f $Item.Name }
        $indent = '  ' * [Math]::Max(0, $node.Depth - 1)
        Write-LogRecord -Id $node.Owner -Tag 'PROC' -Lines @(('{0}pid {1}: {2}' -f $indent, $Item.Pid, $text))
    }
    return $true
}

function Update-ProcWatch {
    if (-not $script:ProcMode) { return }
    foreach ($ev in @(Get-Event -SourceIdentifier $ProcSource -ErrorAction SilentlyContinue)) {
        Remove-Event -EventIdentifier $ev.EventIdentifier -ErrorAction SilentlyContinue
        $e = $ev.SourceEventArgs.NewEvent
        if ($script:ProcMode -eq 'trace') {
            $item = @{ Pid = [int]$e.ProcessID; Ppid = [int]$e.ParentProcessID; Name = [string]$e.ProcessName; Cmd = $null; Seen = Get-Date }
        } else {
            $t = $e.TargetInstance
            $item = @{ Pid = [int]$t.ProcessId; Ppid = [int]$t.ParentProcessId; Name = [string]$t.Name; Cmd = [string]$t.CommandLine; Seen = Get-Date }
        }
        if (-not (Add-ProcEvent $item) -and $script:ProcMode -eq 'poll') { [void]$script:ProcWait.Add($item) }
    }
    # Polled events of one second come in any order: retry children whose parent came later.
    $progress = $true
    while ($progress -and $script:ProcWait.Count -gt 0) {
        $progress = $false
        foreach ($item in @($script:ProcWait)) {
            if (Add-ProcEvent $item) { $script:ProcWait.Remove($item); $progress = $true }
        }
    }
    foreach ($item in @($script:ProcWait)) {
        if (((Get-Date) - $item.Seen).TotalSeconds -gt 3) { $script:ProcWait.Remove($item) }
    }
}

# ---------------------------------------------------------------- settings (before elevation)
$script:SessionLog = $null
$script:LogPos = 0L
try {
    Initialize-DataDir
    $cfgFile = Read-SessionConfig $Config
    if (-not $Duration) { $Duration = '2h'; if ($cfgFile.ContainsKey('duration')) { $Duration = $cfgFile['duration'][-1] } }
    if (-not $Port)     { $Port = 2222;     if ($cfgFile.ContainsKey('port'))     { $Port = [int]$cfgFile['port'][-1] } }
    if (-not $AllowIp -and $cfgFile.ContainsKey('allowip')) { $AllowIp = $cfgFile['allowip'] -join ',' }
    $ips = @($AllowIp -split '[,;\s]+' | Where-Object { $_ })
    $pubKeys = @(Read-AllowedKeys)
    $missing = @()
    if ($pubKeys.Count -eq 0) { $missing += "the PUBLIC key of Claude's workstation to $KeysList" }
    if ($ips.Count -eq 0)     { $missing += "AllowIp (addresses allowed to connect) to $Config" }
    if ($missing.Count) {
        Say 'Not set up yet. Please add:' Yellow
        foreach ($m in $missing) { Say "  - $m" Yellow }
        Say 'then start claude-ssh.bat again. Opening the folder...' Yellow
        try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $DataDir) } catch { }
        if ([Environment]::UserInteractive) { [void](Read-Host 'Press Enter to close') }
        exit 1
    }
} catch {
    Say $_.Exception.Message Red
    if ([Environment]::UserInteractive) { [void](Read-Host 'Press Enter to close') }
    exit 1
}

# ---------------------------------------------------------------- elevation (firewall needs admin)
if (-not $NoFirewall -and -not (Test-IsAdmin)) {
    Say 'Administrator rights are needed (firewall rule). Opening an elevated window...' Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
                 '-Duration', $Duration, '-Port', $Port, '-AllowIp', ('"{0}"' -f $AllowIp),
                 '-ListenAddress', $ListenAddress)
    if ($DataDirGiven) { $argList += @('-DataDir', ('"{0}"' -f $DataDir)) }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null
    return
}

$sshd = $null
$failed = $false
try {
    if (-not (Test-Path (Join-Path $Bin 'sshd.exe'))) { throw "sshd.exe not found in $Bin" }
    $minutes = ConvertTo-Minutes $Duration
    if ($minutes -lt 1 -or $minutes -gt 12 * 60) { throw 'Duration must be between 1 minute and 12 hours.' }
    $deadline = (Get-Date).AddMinutes($minutes)

    # ---- whoever can change this tool can run code here as admin: say so
    foreach ($path in @($Root, $Bin, $PSCommandPath, $Wrapper)) {
        $who = @(Get-BroadWriters $path)
        if ($who.Count) {
            Say ('WARNING: {0} can be changed by {1}. They could run code as you with admin rights. Keep this folder in your profile (e.g. Desktop).' -f $path, ($who -join ', ')) Red
        }
    }

    # ---- leftovers of a previous run that was closed hard
    Stop-OurSshd
    Remove-OurFirewallRule
    foreach ($w in @($Work, (Join-Path $Root 'session'))) {
        if (Test-Path $w) { Remove-Item -Path $w -Recurse -Force }
    }
    New-Item -ItemType Directory -Path $Work | Out-Null

    # ---- host key (generated once)
    $hostKey = Join-Path $KeyDir 'ssh_host_ed25519_key'
    if (-not (Test-Path $hostKey)) {
        if (-not (Test-Path $KeyDir)) { New-Item -ItemType Directory -Path $KeyDir | Out-Null }
        Start-Process -FilePath (Join-Path $Bin 'ssh-keygen.exe') -NoNewWindow -Wait `
            -ArgumentList ('-q -t ed25519 -N "" -C claude-ssh-host -f "{0}"' -f $hostKey)
        if (-not (Test-Path $hostKey)) { throw 'ssh-keygen failed to create the host key.' }
    }
    Set-PrivateAcl $hostKey

    # ---- allowed keys: only from AllowIp, expire by themselves at the deadline
    $expiry = $deadline.ToUniversalTime().ToString('yyyyMMddHHmm') + 'Z'
    $authKeys = Join-Path $Work 'authorized_keys'
    $keyLines = @($pubKeys | ForEach-Object {
        'from="{0}",expiry-time="{1}",no-agent-forwarding,no-port-forwarding,no-X11-forwarding {2}' -f `
            ($ips -join ','), $expiry, $_ })
    Set-Content -Path $authKeys -Value $keyLines -Encoding Ascii
    Set-PrivateAcl $authKeys

    # ---- session log (kept) and sshd config (this session only)
    $script:SessionLog = Join-Path $LogDir ('session-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
    Set-Content -Path $script:SessionLog -Value '' -Encoding Ascii -NoNewline
    $script:LogPos = 0L
    $cfg = Join-Path $Work 'sshd_config'
    @(
        "Port $Port",
        "ListenAddress $ListenAddress",
        ('HostKey "{0}"' -f $hostKey),
        ('AuthorizedKeysFile "{0}"' -f $authKeys),
        'PidFile none',
        'PubkeyAuthentication yes',
        'PasswordAuthentication no',
        'KbdInteractiveAuthentication no',
        'PermitEmptyPasswords no',
        'AllowTcpForwarding no',
        'AllowAgentForwarding no',
        'AllowStreamLocalForwarding no',
        'X11Forwarding no',
        'PermitTunnel no',
        'GatewayPorts no',
        'MaxAuthTries 3',
        'LoginGraceTime 30',
        'ClientAliveInterval 60',
        'LogLevel VERBOSE',
        ('ForceCommand powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Log "{1}"' -f $Wrapper, $script:SessionLog)
    ) | Set-Content -Path $cfg -Encoding Ascii

    # ---- firewall: this port, these IPs only
    if (-not $NoFirewall) {
        New-NetFirewallRule -Name $RuleName -DisplayName 'Claude SSH session (temporary)' `
            -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -RemoteAddress $ips -Profile Any | Out-Null
        Say ("Firewall: port {0} open for {1}" -f $Port, ($ips -join ', ')) Green
    }

    # ---- start sshd as a child of this window (its log goes straight to this console)
    try {
        Enable-KillOnClose
        Say 'Closing this window will kill sshd and every SSH session started from it.' Green
    } catch {
        Say "Could not set up kill-on-close ($($_.Exception.Message)). Use Ctrl+C to stop, not the X button." Red
    }
    Start-ProcWatch
    $env:PATH = "$Bin;$env:PATH"
    $sshd = Start-Process -FilePath (Join-Path $Bin 'sshd.exe') -NoNewWindow -PassThru `
        -ArgumentList ('-D -e -f "{0}"' -f $cfg)
    $script:ProcTree[[int]$sshd.Id] = @{ Role = 'sshd'; Owner = 0; Depth = 0; Interactive = $false }
    Start-Sleep -Seconds 1
    if ($sshd.HasExited) { throw ("sshd exited at start (code {0}), see its messages above." -f $sshd.ExitCode) }

    $fp = (& (Join-Path $Bin 'ssh-keygen.exe') -l -f "$hostKey.pub" | Out-String).Trim()
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $addrs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        ForEach-Object { $_.IPAddress })
    $procNote = 'off (could not subscribe to process events)'
    if ($script:ProcMode -eq 'trace') { $procNote = 'every process' }
    if ($script:ProcMode -eq 'poll')  { $procNote = 'polled once a second (not elevated): very short processes may be missed' }
    Write-Host ''
    Say ('SSH is OPEN until {0:HH:mm} ({1} min). Close this window or press Ctrl+C to stop.' -f $deadline, $minutes) Green
    Say ("Login as: {0}   port: {1}   server IPs: {2}" -f $me, $Port, ($addrs -join ', '))
    Say ("Allowed: {0} key(s) from {1}, from {2}" -f $pubKeys.Count, $KeysList, ($ips -join ', '))
    Say ("Host key: {0}" -f $fp)
    Say ("Session log: {0}" -f $script:SessionLog)
    Say ("Started processes: {0}" -f $procNote)
    Say 'Below: CMD yellow, decoded DEC dark yellow, stdin scripts IN cyan, PROC magenta, FILE green, EXIT.'
    Write-Host ''
    Write-LogRecord -Id 0 -Tag 'NOTE' -Lines @(
        ('SSH open until {0:yyyy-MM-dd HH:mm} as {1}, port {2}, from {3}' -f $deadline, $me, $Port, ($ips -join ', ')),
        ('Host key: {0}' -f $fp), ('Started processes: {0}' -f $procNote))

    # ---- watch: print what happens, stop at the deadline
    while ($true) {
        $left = $deadline - (Get-Date)
        try { $Host.UI.RawUI.WindowTitle = 'Claude SSH - OPEN, {0:hh\:mm\:ss} left - close window to stop' -f $left } catch { }

        Update-ProcWatch
        foreach ($line in @(Read-NewLogLines)) { Show-LogLine $line }
        Complete-Block

        if ($sshd.HasExited) { Say "sshd stopped by itself (code $($sshd.ExitCode))." Red; $failed = $true; break }
        if ($left.TotalSeconds -le 0) { Say 'Time is up - closing everything and this window.' Yellow; break }
        if ($script:ProcMode) {
            [void](Wait-Event -SourceIdentifier $ProcSource -Timeout 1)   # wakes up on a new process
            Start-Sleep -Milliseconds 100
        } else {
            Start-Sleep -Milliseconds 700
        }
    }
} catch {
    Say $_.Exception.Message Red
    $failed = $true
} finally {
    Stop-ProcWatch
    Stop-Descendants
    Stop-OurSshd
    Remove-OurFirewallRule
    if ($script:SessionLog) {
        try { foreach ($line in @(Read-NewLogLines)) { Show-LogLine $line }; Complete-Block } catch { }
        Write-LogRecord -Id 0 -Tag 'NOTE' -Lines @('SSH closed')
    }
    if (Test-Path $Work) { Remove-Item -Path $Work -Recurse -Force -ErrorAction SilentlyContinue }
    try { $Host.UI.RawUI.WindowTitle = 'Claude SSH - CLOSED' } catch { }
    Say 'SSH CLOSED: sshd stopped, key removed, firewall rule removed.' Green
    if ($script:SessionLog) { Say ("Session log: {0}" -f $script:SessionLog) }
}
# Normal end (time is up): just exit, the window closes by itself. On an error, keep it open to read.
if ($failed -and [Environment]::UserInteractive) { [void](Read-Host 'Press Enter to close') }
