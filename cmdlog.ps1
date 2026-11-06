# ForceCommand target for claude-ssh: logs the client's command for the console window,
# then runs it with cmd.exe exactly as sshd would. Keep this file ASCII-only.

$cmd = $env:SSH_ORIGINAL_COMMAND
$log = $env:CLAUDE_SSH_CMDLOG
if (-not $log) { $log = Join-Path $PSScriptRoot 'session\commands.log' }

$shown = $cmd
if (-not $cmd) { $shown = '(interactive shell)' }
# Show -EncodedCommand payloads as readable text.
if ($cmd -and $cmd -match '-(?:e|ec|enc|encodedcommand)\s+([A-Za-z0-9+/=]{8,})') {
    try {
        $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
        $shown = "$cmd`r`n        decoded: $decoded"
    } catch { }
}
$client = ''
if ($env:SSH_CLIENT) { $client = ($env:SSH_CLIENT -split ' ')[0] }
try {
    Add-Content -Path $log -Value ('{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $client, $shown) -Encoding Ascii
} catch { }

$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = Join-Path $env:WINDIR 'System32\cmd.exe'
if ($cmd) { $psi.Arguments = '/c ' + $cmd }
$psi.UseShellExecute = $false
$p = [Diagnostics.Process]::Start($psi)
$p.WaitForExit()
exit $p.ExitCode
