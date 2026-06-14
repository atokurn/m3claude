# m3claude installer for Windows (PowerShell).
# Usage:
#   irm https://raw.githubusercontent.com/YOUR-USERNAME/m3claude/main/install.ps1 | iex

$ErrorActionPreference = 'Stop'

$Repo = 'https://raw.githubusercontent.com/YOUR-USERNAME/m3claude/main'
$Dest = Join-Path $env:LOCALAPPDATA 'Programs\m3claude'

New-Item -ItemType Directory -Force -Path $Dest | Out-Null

Write-Host "Installing m3claude to $Dest ..."
Invoke-WebRequest -UseBasicParsing "$Repo/m3claude.ps1" -OutFile (Join-Path $Dest 'm3claude.ps1')

# A .cmd shim so `m3claude` works from cmd.exe and PowerShell alike.
$shim = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0m3claude.ps1" %*
'@
Set-Content -Path (Join-Path $Dest 'm3claude.cmd') -Value $shim -Encoding ASCII

# Put the install dir on the user PATH if it isn't already.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
if ($userPath -notlike "*$Dest*") {
  $newPath = if ($userPath) { "$userPath;$Dest" } else { $Dest }
  [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
  $env:Path = "$env:Path;$Dest"
  Write-Host "Added $Dest to your user PATH."
  Write-Host 'Open a NEW terminal for it to take effect.'
}

Write-Host 'Installed. Run: m3claude'
