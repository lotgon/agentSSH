# Claude SSH: setup guide for AI agents

**For AI agents** (Claude Code, Claude Desktop and others). A person asked you to set up
[Claude SSH](https://github.com/lotgon/agentSSH) so you can work on their Windows server. This
page says what to check, what to ask, how to build their copy of the tool, what to tell them, and
how to work through it afterwards. Follow it in order.

## What you are making

You run on the person's workstation. You make **`claude-ssh-baked.zip`**: the latest release of
the tool plus a `claude-ssh/baked/` folder with two files:

- `allowed_keys.txt`: the **public** keys allowed to log in, one per line;
- `claude-ssh.config`: the addresses allowed to connect (`AllowIp`), the session length, the port.

The person copies the zip to the server, unzips it and starts `claude-ssh\claude-ssh.bat`. That
opens SSH in a console window for a limited time, only for those keys, only from those addresses,
and shows them everything you run. Closing the window ends your access.

**Rules you must keep:**
- The **private key never leaves this machine**. Never put it in the zip, never show it in the
  chat, never send it anywhere. Only `.pub` lines go into `allowed_keys.txt`.
- Do not guess silently. Propose values, show them, and get a yes before you bake.
- Everything you do on the server is shown to the person and written to a log. Do only what they
  asked for.

## 1. Check what is here

- The operating system of this machine, and that an SSH client is there (`ssh -V`).
- Whether the agent key exists: `~/.ssh/claude-access_ed25519` and `.pub` (on Windows
  `%USERPROFILE%\.ssh\claude-access_ed25519`). If the person already uses another key for you,
  use that one.
- That the latest release is v0.2.0 or newer: <https://github.com/lotgon/agentSSH/releases/latest>.
  Older versions cannot bake.

## 2. Ask the person

Ask in one message, with your proposals filled in, so they can just answer "yes":

1. **Keys.** "I will log in with a key of my own, `~/.ssh/claude-access_ed25519` (I will create it
   if it is missing). Should anyone or anything else be able to log in too, for example your
   other computers or a colleague's agent? Send me their **public** keys (`.pub` lines)."
2. **Addresses.** "How does this computer reach the server: over the internet, in the same office
   network, or over a VPN? Will you connect from other places too (home, office, VPN)?" Then
   propose the addresses (see below) and ask to confirm them.
3. **Length and port.** "A session lasts 2 hours by default, 12 at most. Another default? The
   port is 2222, unless a firewall in front of the server needs another."

**Finding the addresses.** `AllowIp` must be the address **the server sees** you come from:
- over the internet: this machine's public address, for example `curl -s https://api.ipify.org`
  (tell the person you ask that outside service). Home connections often change their address:
  then offer the provider's subnet, or say that a changed address means baking again;
- in the same network or over a VPN: this machine's address on that network (`ipconfig` on
  Windows, `ip -4 addr` on Linux, `ipconfig getifaddr en0` on macOS), or the whole VPN subnet,
  for example `10.8.0.0/24`;
- several places: one `AllowIp` line each. Subnets are fine.

## 3. Make the key, if it is missing

macOS, Linux, or Git Bash on Windows:
```bash
ssh-keygen -t ed25519 -N "" -C claude-access -f ~/.ssh/claude-access_ed25519
```
Windows, from any shell:
```bat
cmd /c ssh-keygen -t ed25519 -N "" -C claude-access -f "%USERPROFILE%\.ssh\claude-access_ed25519"
```
No passphrase, so you can use it without a person typing it. It only works on servers that baked
its public half, only from `AllowIp`, only while their window is open. If the person wants a
passphrase, use `ssh-agent`.

## 4. Bake the copy

Write the two files with the values the person confirmed. `allowed_keys.txt`, one public key per
line:
```text
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... claude-access
```
`claude-ssh.config`:
```ini
AllowIp = 203.0.113.10
AllowIp = 10.8.0.0/24
Duration = 2h
Port = 2222
```

**On Windows** (PowerShell), the tool checks and bakes them for you:
```powershell
$w = Join-Path $env:TEMP ('claude-ssh-bake-' + (Get-Random))
New-Item -ItemType Directory "$w\settings" | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest https://github.com/lotgon/agentSSH/releases/latest/download/claude-ssh.zip -OutFile "$w\claude-ssh.zip" -UseBasicParsing
Expand-Archive "$w\claude-ssh.zip" $w
# now write allowed_keys.txt and claude-ssh.config into $w\settings, then:
& "$w\claude-ssh\claude-ssh.bat" -Bake -DataDir "$w\settings"
```
`-Bake` refuses a private key, a line that is not a public key, a config without `AllowIp` and a
bad `Duration`. It writes `claude-ssh-baked.zip` to the Desktop (`-BakeTo <path>` for another
place) and prints the number of keys and the addresses: check that they are what the person
agreed to.

**On macOS or Linux** you build the zip yourself:
```bash
w=$(mktemp -d) && cd "$w"
curl -fsSL -o claude-ssh.zip https://github.com/lotgon/agentSSH/releases/latest/download/claude-ssh.zip
unzip -q claude-ssh.zip                       # makes claude-ssh/
mkdir claude-ssh/baked
# now write claude-ssh/baked/allowed_keys.txt and claude-ssh/baked/claude-ssh.config, then:
grep -rl "PRIVATE KEY" claude-ssh/baked && echo "STOP: a private key"
zip -qr ~/claude-ssh-baked.zip claude-ssh    # or: python3 -m zipfile -c ~/claude-ssh-baked.zip claude-ssh
```
Nothing checks the files here, so check them yourself before zipping: every line of
`allowed_keys.txt` starts with `ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-` or `sk-`; no file in
`baked/` contains `PRIVATE KEY`; the config has at least one `AllowIp`, a `Duration` between `1m`
and `12h` and a `Port`.

## 5. Tell the person what to do

Something like this, with the real values:
```text
Your copy of Claude SSH is ready: <path to claude-ssh-baked.zip>
It lets in <N> key(s) (<whose>) from <addresses>; a session lasts <2h>, port <2222>.

1. Copy the zip to the server (through RDP, for example) into your profile: the Desktop is
   fine, C:\ or C:\Tools is not.
2. Unzip it and start claude-ssh\claude-ssh.bat. Confirm the administrator prompt.
3. Copy the cyan line that starts with "For the agent:" from the window and send it to me.

The window shows everything I run. Close it to cut me off.
```
Add when it applies:
- downloaded with a browser on the server: open the zip's **Properties** and tick **Unblock**
  before unzipping;
- the server is in a cloud or behind a router: its security group or port forwarding must also
  let port 2222 in from those addresses. The tool only opens Windows Firewall.

## 6. Connect

The person sends a line like:
```text
For the agent: user admin, port 2222, server IPs 198.51.100.7 10.0.0.5, host key SHA256:7mQ0c3vY..., open until 16:30
```
1. Pick the server IP you can reach: the public one over the internet, the network or VPN one
   otherwise. Ask if unsure.
2. **Check the host key before trusting it.** This must print the same `SHA256:...`:
   ```bash
   ssh-keyscan -p 2222 -t ed25519 198.51.100.7 2>/dev/null | ssh-keygen -lf -
   ```
   If it differs, stop and tell the person. If it matches, add it:
   `ssh-keyscan -p 2222 -t ed25519 198.51.100.7 >> ~/.ssh/known_hosts`.

   On Windows, the `ssh-keyscan` built into Windows (OpenSSH 9.5) prints nothing here and fails
   with `choose_kex: unsupported KEX method sntrup761x25519-sha512@openssh.com`. Use the one in the
   tool folder you unpacked while baking, `claude-ssh\OpenSSH-Win64\ssh-keyscan.exe` (OpenSSH
   10.0), or the one of Git for Windows. `ssh` and `ssh-keygen` built into Windows work fine.
3. Test: `ssh -i ~/.ssh/claude-access_ed25519 -p 2222 admin@198.51.100.7 "whoami"`.
4. Remember the host, port, user, key path and fingerprint for next time (never the private
   key). Each server has its own host key; the same server keeps it across sessions.

## Working through Claude SSH

- Every command runs as `cmd.exe /c <command>`, as the person's Windows account, with
  administrator rights. Quotes, `&`, `|` and exit codes work as usual.
- PowerShell one-liners: `ssh ... "powershell -NoProfile -Command \"Get-Service sshd\""`.
- Longer PowerShell scripts: send them on stdin with this fixed bootstrap. It is
  `$ProgressPreference="SilentlyContinue"; $s=[Console]::In.ReadToEnd(); Invoke-Expression $s`
  in base64 (UTF-16LE); the window decodes it and shows your script:
  ```bash
  ssh -i ~/.ssh/claude-access_ed25519 -p 2222 admin@198.51.100.7 "powershell -NoProfile -EncodedCommand JABQAHIAbwBnAHIAZQBzAHMAUAByAGUAZgBlAHIAZQBuAGMAZQA9ACIAUwBpAGwAZQBuAHQAbAB5AEMAbwBuAHQAaQBuAHUAZQAiADsAIAAkAHMAPQBbAEMAbwBuAHMAbwBsAGUAXQA6ADoASQBuAC4AUgBlAGEAZABUAG8ARQBuAGQAKAApADsAIABJAG4AdgBvAGsAZQAtAEUAeABwAHIAZQBzAHMAaQBvAG4AIAAkAHMA" < script.ps1
  ```
- Files: there is no `scp` or `sftp`. Send a file as base64 text on stdin and write it with
  `[IO.File]::WriteAllBytes('C:\path\file', [Convert]::FromBase64String($b64))`. Keep each command
  under about **2 MB of stdin**; send bigger files in chunks (append to a `.b64` file, decode at
  the end). Read files back with `type` or `[Convert]::ToBase64String(...)`.
- Text output: `cmd` prints in the console code page, so non-English letters may come back as
  `?`. In PowerShell, start with `[Console]::OutputEncoding = [Text.Encoding]::UTF8`.
- Avoid interactive programs. `ssh -t` works, but its keystrokes are not logged.
- Access ends at "open until": the key stops working and the window closes. Ask the person for a
  new session when you need one.
