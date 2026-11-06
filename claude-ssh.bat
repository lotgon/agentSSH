@echo off
rem Starts SSH for Claude in THIS window. Close the window or press Ctrl+C to stop it.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-ssh.ps1" %*
