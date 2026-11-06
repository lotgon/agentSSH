# Claude SSH session: runs sshd in THIS window.
# Close the window, press Ctrl+C, or let the time run out = SSH is gone.
#
#   claude-ssh.bat              (2 hours)
#   claude-ssh.bat -Duration 4h
#
# Nothing is installed and no Windows service is used: portable, Microsoft-signed
# OpenSSH from .\OpenSSH-Win64 runs as YOUR account, so only your account can log in,
# only with Claude's key, only from AllowIp. Every command Claude runs is printed here.
# Keep this file ASCII-only (Windows PowerShell 5.1).

# Defaults come from claude-ssh.config next to this script; parameters override them.
param(
    [string]$Duration = '',
    [int]$Port = 0,
    [string]$AllowIp = '',
    [string]$ListenAddress = '0.0.0.0',
    [switch]$NoFirewall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Root     = $PSScriptRoot
$Config   = Join-Path $Root 'claude-ssh.config'
$KeysList = Join-Path $Root 'allowed_keys.txt'
$Bin      = Join-Path $Root 'OpenSSH-Win64'
$KeyDir   = Join-Path $Root 'hostkey'      # kept between runs: stable fingerprint
$Work     = Join-Path $Root 'session'      # wiped at start and at stop
$RuleName = 'Claude-SSH-session'

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

$cfgFile = Read-SessionConfig $Config
if (-not $Duration) { $Duration = '2h'; if ($cfgFile.ContainsKey('duration')) { $Duration = $cfgFile['duration'][-1] } }
if (-not $Port)     { $Port = 2222;     if ($cfgFile.ContainsKey('port'))     { $Port = [int]$cfgFile['port'][-1] } }
if (-not $AllowIp -and $cfgFile.ContainsKey('allowip')) { $AllowIp = $cfgFile['allowip'] -join ',' }

# ---------------------------------------------------------------- elevation (firewall needs admin)
if (-not $NoFirewall -and -not (Test-IsAdmin)) {
    Say 'Administrator rights are needed (firewall rule). Opening an elevated window...' Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
                 '-Duration', $Duration, '-Port', $Port, '-AllowIp', ('"{0}"' -f $AllowIp),
                 '-ListenAddress', $ListenAddress)
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
    $ips = @($AllowIp -split '[,;\s]+' | Where-Object { $_ })
    if ($ips.Count -eq 0) { throw "No AllowIp given (claude-ssh.config or -AllowIp)." }
    if (-not (Test-Path $KeysList)) { throw "Key list not found: $KeysList" }
    $pubKeys = @(Get-Content -Path $KeysList | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') })
    foreach ($k in $pubKeys) {
        if ($k -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-\S+|sk-\S+) [A-Za-z0-9+/=]+') { throw "Not a public key line in allowed_keys.txt: $k" }
    }
    if ($pubKeys.Count -eq 0) { throw 'allowed_keys.txt has no keys.' }

    # ---- leftovers of a previous run that was closed hard
    Stop-OurSshd
    Remove-OurFirewallRule
    if (Test-Path $Work) { Remove-Item -Path $Work -Recurse -Force }
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

    # ---- sshd config for this session only
    $cmdLog  = Join-Path $Work 'commands.log'
    $wrapper = Join-Path $Root 'cmdlog.ps1'
    $cfg     = Join-Path $Work 'sshd_config'
    Set-Content -Path $cmdLog -Value '' -Encoding Ascii
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
        ('ForceCommand powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $wrapper)
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
    $env:PATH = "$Bin;$env:PATH"
    $env:CLAUDE_SSH_CMDLOG = $cmdLog
    $sshd = Start-Process -FilePath (Join-Path $Bin 'sshd.exe') -NoNewWindow -PassThru `
        -ArgumentList ('-D -e -f "{0}"' -f $cfg)
    Start-Sleep -Seconds 1
    if ($sshd.HasExited) { throw ("sshd exited at start (code {0}), see its messages above." -f $sshd.ExitCode) }

    $fp = (& (Join-Path $Bin 'ssh-keygen.exe') -l -f "$hostKey.pub" | Out-String).Trim()
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $addrs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        ForEach-Object { $_.IPAddress })
    Write-Host ''
    Say ('SSH is OPEN until {0:HH:mm} ({1} min). Close this window or press Ctrl+C to stop.' -f $deadline, $minutes) Green
    Say ("Login as: {0}   port: {1}   server IPs: {2}" -f $me, $Port, ($addrs -join ', '))
    Say ("Allowed: {0} key(s) from allowed_keys.txt, from {1}" -f $pubKeys.Count, ($ips -join ', '))
    Say ("Host key: {0}" -f $fp)
    Say 'Commands Claude runs appear below in yellow.'
    Write-Host ''

    # ---- watch: print commands, stop at the deadline
    $seenCmd = 0
    while ($true) {
        $left = $deadline - (Get-Date)
        $Host.UI.RawUI.WindowTitle = 'Claude SSH - OPEN, {0:hh\:mm\:ss} left - close window to stop' -f $left

        $cmds = @(Get-Content -Path $cmdLog -ErrorAction SilentlyContinue | Where-Object { $_ })
        for ($i = $seenCmd; $i -lt $cmds.Count; $i++) { Write-Host "  CMD  $($cmds[$i])" -ForegroundColor Yellow }
        $seenCmd = $cmds.Count

        if ($sshd.HasExited) { Say "sshd stopped by itself (code $($sshd.ExitCode))." Red; $failed = $true; break }
        if ($left.TotalSeconds -le 0) { Say 'Time is up - closing everything and this window.' Yellow; break }
        Start-Sleep -Milliseconds 700
    }
} catch {
    Say $_.Exception.Message Red
    $failed = $true
} finally {
    Stop-Descendants
    Stop-OurSshd
    Remove-OurFirewallRule
    if (Test-Path $Work) {
        Copy-Item -Path (Join-Path $Work 'commands.log') -Destination (Join-Path $Root ('last-session-commands-{0:yyyyMMdd-HHmm}.log' -f (Get-Date))) -ErrorAction SilentlyContinue
        Remove-Item -Path $Work -Recurse -Force -ErrorAction SilentlyContinue
    }
    $Host.UI.RawUI.WindowTitle = 'Claude SSH - CLOSED'
    Say 'SSH CLOSED: sshd stopped, key removed, firewall rule removed.' Green
}
# Normal end (time is up): just exit, the window closes by itself. On an error, keep it open to read.
if ($failed -and [Environment]::UserInteractive) { [void](Read-Host 'Press Enter to close') }
