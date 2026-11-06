# Claude SSH session: runs sshd in THIS window.
# Close the window, press Ctrl+C, or let the time run out = SSH is gone.
#
#   claude-ssh.bat              (2 hours)
#   claude-ssh.bat -Duration 4h
#   claude-ssh.bat -Bake        (no SSH: zips this tool with your settings from
#                                %LOCALAPPDATA%\ClaudeSSH; unzip it on any server and start it)
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
    [switch]$NoFirewall,
    [switch]$Bake,              # build a baked copy instead of opening SSH
    [string]$BakeTo = ''        # -Bake: the zip to write (default: Desktop\claude-ssh-baked.zip)
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
$BakedDir = Join-Path $Root 'baked'        # settings carried by a baked copy
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
# Not the conhost.exe of this window itself (an elevated window owns one): killing it would
# take the window away before it says what happened.
function Stop-Descendants {
    $all = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)
    $found = New-Object System.Collections.Generic.List[int]
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($PID)
    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        foreach ($p in $all) {
            $id = [int]$p.ProcessId
            if ($parent -eq $PID -and "$($p.Name)" -eq 'conhost.exe') { continue }
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
    param([string]$Path = $KeysList)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    # The marker of a private key file, case-sensitive: the template's comments say "private key".
    $text = Get-Content -LiteralPath $Path -Raw
    if ($text -cmatch '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----') {
        throw "$Path holds a PRIVATE key. Use the .pub file: the private key must stay on the workstation."
    }
    $keys = @(Get-Content -LiteralPath $Path | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') })
    foreach ($k in $keys) {
        if ($k -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-\S+|sk-\S+) [A-Za-z0-9+/=]+') { throw "Not a public key line in ${Path}: $k" }
    }
    return $keys
}

# ---------------------------------------------------------------- baked copy
# Set up one server, then claude-ssh.bat -Bake writes a zip of this tool plus .\baked\ with a
# copy of its allowed_keys.txt and claude-ssh.config (all keys, all addresses, as they are).
# Unzipped on a server, the first start copies .\baked\ into the data folder. A different bake
# (another key, other addresses) is copied once more, the old files kept as *.bak; changes
# made by hand after that stay until the next different bake. The host key is never baked:
# every server makes its own.
$BakedNames = @('claude-ssh.config', 'allowed_keys.txt')
$ToolFiles  = @('claude-ssh.bat', 'claude-ssh.ps1', 'cmdlog.ps1', 'OpenSSH-Win64', 'README.md', 'assets',
                'allowed_keys.example.txt', 'claude-ssh.config.example')

# The settings of a file without comments and blank lines: a new bake date is not a change.
function Get-SettingsText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return ((Get-Content -LiteralPath $Path | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }) -join "`n")
}

function Install-BakedSettings {
    $present = @($BakedNames | Where-Object { Test-Path (Join-Path $BakedDir $_) })
    if (-not $present.Count) { return }
    $stamp = ($present | ForEach-Object { $_ + '=' + (Get-SettingsText (Join-Path $BakedDir $_)) }) -join "`n"
    $stamp = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash(
        [Text.Encoding]::UTF8.GetBytes($stamp))).Replace('-', '')
    $stampFile = Join-Path $DataDir 'baked.applied'
    if ((Test-Path $stampFile) -and ((Get-Content -LiteralPath $stampFile -Raw).Trim() -eq $stamp)) { return }
    $copied = @()
    foreach ($name in $present) {
        $src = Join-Path $BakedDir $name
        $dst = Join-Path $DataDir $name
        if ((Test-Path $dst) -and (Get-SettingsText $dst) -eq (Get-SettingsText $src)) { continue }
        if (Test-Path $dst) { Copy-Item -LiteralPath $dst -Destination ('{0}.{1:yyyyMMdd-HHmmss}.bak' -f $dst, (Get-Date)) -Force }
        Copy-Item -LiteralPath $src -Destination $dst -Force
        $copied += $name
    }
    Set-Content -LiteralPath $stampFile -Value $stamp -Encoding Ascii
    if ($copied.Count) { Say ('Baked settings copied to {0}: {1}' -f $DataDir, ($copied -join ', ')) Green }
}

# -Bake: the code of THIS folder (so an updated folder bakes the new version) and the settings
# of this machine exactly as they are set up in the data folder. Already checked by the caller:
# keys, addresses, duration. Written to Desktop\claude-ssh-baked.zip (or -BakeTo).
function New-BakedCopy {
    param([string[]]$Keys, [string[]]$Ips, [string]$Dur, [int]$Prt)
    $out = $BakeTo
    if (-not $out) { $out = Join-Path ([Environment]::GetFolderPath('Desktop')) 'claude-ssh-baked.zip' }
    $out = [IO.Path]::GetFullPath($out)
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('claude-ssh-bake-' + [Guid]::NewGuid().ToString('N'))
    $dst = Join-Path $stage 'claude-ssh'
    try {
        New-Item -ItemType Directory -Path (Join-Path $dst 'baked') -Force | Out-Null
        foreach ($item in $ToolFiles) {
            $src = Join-Path $Root $item
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force }
        }
        foreach ($name in $BakedNames) {   # byte for byte: comments and all
            Copy-Item -LiteralPath (Join-Path $DataDir $name) -Destination (Join-Path $dst "baked\$name")
        }
        Set-Content -Path (Join-Path $dst 'baked\README.txt') -Encoding Ascii -Value @(
            ('Baked by claude-ssh.bat -Bake on {0:yyyy-MM-dd HH:mm} from the settings in %LOCALAPPDATA%\ClaudeSSH.' -f (Get-Date)),
            'The first start of this copy copies allowed_keys.txt and claude-ssh.config to',
            '%LOCALAPPDATA%\ClaudeSSH on the server (an older, different file is kept as *.bak).',
            'To change them for all servers: change them on one server, bake again, copy the new zip.')
        if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
        # Entry by entry: ZipFile.CreateFromDirectory in Windows PowerShell 5.1 writes "\" into
        # the names, which other unzip tools turn into odd file names.
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::Open($out, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($f in @(Get-ChildItem -LiteralPath $stage -Recurse -File)) {
                $name = $f.FullName.Substring($stage.Length + 1).Replace('\', '/')
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $name,
                    [IO.Compression.CompressionLevel]::Optimal)
            }
        } finally { $zip.Dispose() }
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
    Say ('Baked: {0}' -f $out) Green
    Say ('  code from:     {0}' -f $Root)
    Say ('  settings from: {0}' -f $DataDir)
    Say ('  {0} key(s); AllowIp {1}; port {2}; {3} by default' -f $Keys.Count, ($Ips -join ', '), $Prt, $Dur)
    Say '  Copy it to a server, unzip, start claude-ssh\claude-ssh.bat: nothing else to set up.'
    Say '  It holds your public keys and addresses: share it like a config file, not publicly.'
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

    Install-BakedSettings

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
# One line per record: "yyyy-MM-dd HH:mm:ss #<id> TAG text". cmdlog.ps1 (one per command,
# <id> = its PID) and this window (SSH, PROC and NOTE records, <id> 0 for the server itself)
# append to the same file; the window prints new lines, except the output of commands.
$LogHeader = @(
    '# Claude SSH session log. One record per line: date time #id TAG text',
    '# #id = one command (the PID of its cmdlog.ps1), #0 = the server itself',
    '# SSH  sshd: connections, logins (with key fingerprint), failed attempts, disconnects',
    '# CMD  command line and client IP      DEC  decoded powershell -EncodedCommand',
    '# IN   text sent on stdin (scripts)    OUT, ERR  what the command printed (stdout, stderr)',
    '# PROC programs the command started    FILE files it wrote, with content',
    '# EXIT exit code and run time          NOTE everything else',
    '# "| text" lines continue the record above them. Long text is cut at 1 MB per command.'
)

function Write-LogRecord {
    param([string]$Id, [string]$Tag, [string[]]$Lines, $Time = $null)
    if (-not $script:SessionLog -or -not $Lines) { return }
    if (-not $Time) { $Time = Get-Date }
    $stamp = $Time.ToString('yyyy-MM-dd HH:mm:ss')
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

$TagColors = @{ CMD = 'Yellow'; DEC = 'DarkYellow'; IN = 'Cyan'; FILE = 'Green'; PROC = 'Magenta'; EXIT = 'DarkGray'; NOTE = 'DarkGray'; SSH = 'DarkGray' }
$WindowHides = @{ OUT = $true; ERR = $true }   # in the log only: the window would drown in it
# sshd lines that mean someone did not get in (or something broke): red. Logins: white.
$SshBad = '(?i)failed|invalid user|refused|not allowed|authenticating user|maximum authentication|unable to negotiate|bad protocol|^error: |penali'
# Routine sshd lines of every command: in the log only (a login line per command stays).
$SshRoutine = '^(Connection from |Accepted key |User child is on pid )|Postponed publickey|Starting session: |Close session: |Received disconnect from |Disconnected from .*\[postauth\]|Read error from remote host .*\[postauth\]|Transferred: '
$script:BlockKey = ''; $script:BlockCount = 0; $script:BlockHidden = 0
$script:Running = @{}   # commands with a CMD record and no EXIT yet: id -> start time

function Complete-Block {
    if ($script:BlockHidden -gt 0) {
        Write-Host ('           ... {0} more line(s): see the session log' -f $script:BlockHidden) -ForegroundColor DarkGray
        $script:BlockHidden = 0
    }
}

function Show-LogLine {
    param([string]$Line)
    $Line = $Line.TrimStart([char]0xFEFF)
    if ($Line.StartsWith('#')) { return }   # the header
    if ($Line -notmatch '^(?:\d{4}-\d\d-\d\d )?(\d\d:\d\d:\d\d) #(\d+) (\w+)\s+(.*)$') { Complete-Block; Write-Host $Line; return }
    $time = $Matches[1]; $id = $Matches[2]; $tag = $Matches[3]; $text = $Matches[4]
    if ($tag -eq 'CMD' -and -not $text.StartsWith('|')) { $script:Running[$id] = $time }
    if ($tag -eq 'EXIT') { $script:Running.Remove($id) }
    if ($id -eq '0' -and $tag -ne 'PROC' -and $tag -ne 'SSH') { return }   # this window's own notes: already printed
    if ($WindowHides.ContainsKey($tag)) { return }
    if ($tag -eq 'SSH' -and $text -match $SshRoutine -and $text -notmatch $SshBad) { return }
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
    if ($tag -eq 'SSH') {
        if ($text -match $SshBad) { $color = 'Red' } elseif ($text -match '^Accepted publickey') { $color = 'White' }
    }
    $who = ''
    if ($id -ne '0') { $who = "#$id" }
    Write-Host ('  {0} {1,-6} {2,-4} {3}' -f $time, $who, $tag, (Format-ForConsole $text)) -ForegroundColor $color
}

# ---------------------------------------------------------------- sshd messages
# sshd (and the per-connection processes it starts) write to its stderr, a pipe read by
# .NET in the background: every line becomes an event, here turned into an SSH record.
$SshdSource = 'ClaudeSshSshd'

function Start-Sshd {
    param([string]$ConfigPath)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $Bin 'sshd.exe'
    $psi.Arguments = '-D -e -f "{0}"' -f $ConfigPath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $psi
    Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -SourceIdentifier $SshdSource | Out-Null
    [void]$proc.Start()
    $proc.BeginErrorReadLine()
    return $proc
}

function Update-SshdLog {
    foreach ($ev in @(Get-Event -SourceIdentifier $SshdSource -ErrorAction SilentlyContinue)) {
        Remove-Event -EventIdentifier $ev.EventIdentifier -ErrorAction SilentlyContinue
        $line = $ev.SourceEventArgs.Data
        if (-not $line) { continue }   # $null = end of the stream
        Write-LogRecord -Id 0 -Tag 'SSH' -Lines @($line.TrimEnd()) -Time $ev.TimeGenerated
    }
}

function Stop-SshdLog {
    Unregister-Event -SourceIdentifier $SshdSource -ErrorAction SilentlyContinue
    Remove-Event -SourceIdentifier $SshdSource -ErrorAction SilentlyContinue
}

# Everything new: sshd messages into the log, then the log into the window.
function Update-Window {
    Update-SshdLog
    foreach ($line in @(Read-NewLogLines)) { Show-LogLine $line }
    Complete-Block
}

# ---------------------------------------------------------------- process watch
# Every process started under our sshd is put in a tree. Shown (as PROC records):
# what Claude's commands start. Hidden: sshd itself, cmdlog.ps1, its cmd.exe /c, the
# command itself (it is already shown as CMD) and conhost.exe.
$script:ProcMode = ''
$script:ProcTree = @{}
$script:ProcWait = New-Object System.Collections.ArrayList
$script:ProcPruned = Get-Date

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

function Get-ProcStart {
    param([int]$ProcId)
    try { return (Get-Process -Id $ProcId -ErrorAction Stop).StartTime } catch { return $null }
}

# Windows reuses process IDs. True if the process with this ID is still the one we recorded
# (started at $Start), or has ended: then late children of it are still ours.
function Test-SameProcess {
    param([int]$ProcId, $Start)
    $p = Get-Process -Id $ProcId -ErrorAction SilentlyContinue
    if (-not $p) { return $true }
    if (-not $Start) { return $false }   # ours ended before we saw it: this one is someone else
    try { return ($p.StartTime -eq $Start) } catch { return $false }
}

# Forget processes that ended (a few seconds after we saw them: late children may still come).
function Remove-EndedProcs {
    if (((Get-Date) - $script:ProcPruned).TotalSeconds -lt 5) { return }
    $script:ProcPruned = Get-Date
    $live = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $live[[int]$p.Id] = $p }
    foreach ($id in @($script:ProcTree.Keys)) {
        $node = $script:ProcTree[$id]
        if ($node.Role -eq 'sshd' -or ((Get-Date) - $node.Added).TotalSeconds -lt 5) { continue }
        $same = $false
        $p = $live[[int]$id]
        if ($p -and $node.Start) { try { $same = ($p.StartTime -eq $node.Start) } catch { } }
        if (-not $same) { $script:ProcTree.Remove($id) }
    }
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
    if (-not (Test-SameProcess $Item.Ppid $parent.Start)) {   # the parent ID now belongs to another process
        $script:ProcTree.Remove($Item.Ppid); return $false
    }
    $cl = $Item.Cmd
    if (-not $cl) { $cl = Get-ProcCmdLine $Item.Pid }
    $name = "$($Item.Name)".ToLowerInvariant()
    $node = @{ Role = 'child'; Owner = $parent.Owner; Depth = $parent.Depth + 1; Interactive = $parent.Interactive
               Start = (Get-ProcStart $Item.Pid); Added = (Get-Date) }
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
    Remove-EndedProcs
}

# ---------------------------------------------------------------- settings (before elevation)
# -Bake goes the same way: the same data folder, the same check, then the zip instead of SSH.
$script:SessionLog = $null
$script:LogPos = 0L
try {
    if ($Bake -and ($AllowIp -or $Port -or $Duration)) {
        throw ('-Bake takes the settings exactly as they are set up in {0}. Put AllowIp, Port and Duration into claude-ssh.config there, then bake.' -f $DataDir)
    }
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
        $again = 'start claude-ssh.bat again'
        if ($Bake) { $again = 'run claude-ssh.bat -Bake again' }
        Say "then $again. Opening the folder..." Yellow
        try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $DataDir) } catch { }
        if ([Environment]::UserInteractive) { [void](Read-Host 'Press Enter to close') }
        exit 1
    }
    if ($Bake) {
        $minutes = ConvertTo-Minutes $Duration
        if ($minutes -lt 1 -or $minutes -gt 12 * 60) { throw 'Duration must be between 1 minute and 12 hours.' }
        New-BakedCopy -Keys $pubKeys -Ips $ips -Dur $Duration -Prt $Port
        exit 0
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
        # Not Start-Process -Wait: in Windows PowerShell 5.1 it can throw "the process has exited"
        # when ssh-keygen is quick, which stopped the very first start of a new server.
        $kg = New-Object Diagnostics.ProcessStartInfo
        $kg.FileName = Join-Path $Bin 'ssh-keygen.exe'
        $kg.Arguments = '-q -t ed25519 -N "" -C claude-ssh-host -f "{0}"' -f $hostKey
        $kg.UseShellExecute = $false
        ([Diagnostics.Process]::Start($kg)).WaitForExit()
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
    # UTF-8 with a BOM, so Windows PowerShell 5.1 and old editors read non-English text right.
    [IO.File]::WriteAllText($script:SessionLog, (($LogHeader -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($true)))
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

    # ---- start sshd as a child of this window (its messages go to the session log and here)
    try {
        Enable-KillOnClose
        Say 'Closing this window will kill sshd and every SSH session started from it.' Green
    } catch {
        Say "Could not set up kill-on-close ($($_.Exception.Message)). Use Ctrl+C to stop, not the X button." Red
    }
    Start-ProcWatch
    $env:PATH = "$Bin;$env:PATH"
    $sshd = Start-Sshd $cfg
    $sshdStart = $null
    try { $sshdStart = $sshd.StartTime } catch { }   # sshd may already have exited: said below
    $script:ProcTree[[int]$sshd.Id] = @{ Role = 'sshd'; Owner = 0; Depth = 0; Interactive = $false
                                         Start = $sshdStart; Added = (Get-Date) }
    Start-Sleep -Seconds 1
    Update-Window
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
    Say '  it keeps everything below with dates, plus what each command printed (OUT, ERR: not shown here)'
    Say ("Started processes: {0}" -f $procNote)
    Say 'Below: SSH logins (failed: red), CMD yellow, DEC dark yellow, IN cyan, PROC magenta, FILE green, EXIT.'
    Write-Host ''
    Write-LogRecord -Id 0 -Tag 'NOTE' -Lines @(
        ('SSH open until {0:yyyy-MM-dd HH:mm} as {1}, port {2}, from {3}' -f $deadline, $me, $Port, ($ips -join ', ')),
        ('Host key: {0}' -f $fp), ('Started processes: {0}' -f $procNote))

    # ---- watch: print what happens, stop at the deadline
    while ($true) {
        $left = $deadline - (Get-Date)
        try { $Host.UI.RawUI.WindowTitle = 'Claude SSH - OPEN, {0:hh\:mm\:ss} left - close window to stop' -f $left } catch { }

        Update-ProcWatch
        Update-Window

        if ($sshd.HasExited) { Say "sshd stopped by itself (code $($sshd.ExitCode))." Red; $failed = $true; break }
        if ($left.TotalSeconds -le 0) { Say 'Time is up - closing everything and this window.' Yellow; break }
        [void](Wait-Event -Timeout 1)   # wakes up on a new process or an sshd message
        Start-Sleep -Milliseconds 100
    }
} catch {
    Say $_.Exception.Message Red
    $failed = $true
} finally {
    Stop-ProcWatch
    Stop-Descendants
    Stop-OurSshd
    Remove-OurFirewallRule
    if (Test-Path $Work) { Remove-Item -Path $Work -Recurse -Force -ErrorAction SilentlyContinue }
    # The log first, the window after: a broken window must not cost the log its end.
    $stopped = @()
    if ($script:SessionLog) {
        Start-Sleep -Milliseconds 300   # the last sshd messages
        try { Update-SshdLog } catch { }
        foreach ($line in @(Read-NewLogLines)) { try { Show-LogLine $line } catch { } }
        foreach ($id in @($script:Running.Keys)) {
            Write-LogRecord -Id $id -Tag 'NOTE' -Lines @(('(started {0}, still running when SSH closed: stopped, no EXIT)' -f $script:Running[$id]))
            $stopped += ('#{0} (started {1})' -f $id, $script:Running[$id])
        }
        Write-LogRecord -Id 0 -Tag 'NOTE' -Lines @('SSH closed')
    }
    Stop-SshdLog
    try { $Host.UI.RawUI.WindowTitle = 'Claude SSH - CLOSED' } catch { }
    try {
        Complete-Block
        if ($stopped.Count) { Say ('Still running, stopped: {0}' -f ($stopped -join ', ')) Yellow }
        Say 'SSH CLOSED: sshd stopped, key removed, firewall rule removed.' Green
        if ($script:SessionLog) { Say ("Session log: {0}" -f $script:SessionLog) }
    } catch { }
}
# Normal end (time is up): just exit, the window closes by itself. On an error, keep it open to read.
if ($failed -and [Environment]::UserInteractive) { [void](Read-Host 'Press Enter to close') }
