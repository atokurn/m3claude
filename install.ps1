# m3claude installer for Windows (PowerShell).
# Usage:
#   irm https://raw.githubusercontent.com/atokurn/m3claude/main/install.ps1 | iex

$ErrorActionPreference = 'Stop'

$Repo = 'https://raw.githubusercontent.com/atokurn/m3claude/main'
$Dest = Join-Path $env:LOCALAPPDATA 'Programs\m3claude'

New-Item -ItemType Directory -Force -Path $Dest | Out-Null

Write-Host "Installing m3claude to $Dest ..."
Invoke-WebRequest -UseBasicParsing "$Repo/m3claude.ps1" -OutFile (Join-Path $Dest 'm3claude.ps1')
Invoke-WebRequest -UseBasicParsing "$Repo/proxy.py"      -OutFile (Join-Path $Dest 'proxy.py')

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

# Ensure auto-compact is explicitly enabled for m3claude sessions.
# TokenRouter / MiniMax-M3 benefits from context summarization when the
# context window fills; the Claude Code default is also true, but writing
# it explicitly makes the behavior obvious and survives upstream default
# changes. Honored as-is: users can still set DISABLE_AUTO_COMPACT=1 in
# their environment to override.
$ClaudeSettingsDir  = Join-Path $env:USERPROFILE '.claude'
$ClaudeSettingsFile = Join-Path $ClaudeSettingsDir 'settings.json'
New-Item -ItemType Directory -Force -Path $ClaudeSettingsDir | Out-Null

function Set-AutoCompact {
  param([string]$Path)
  $data = @{}
  if (Test-Path $Path) {
    try {
      $existing = Get-Content -Raw -Path $Path | ConvertFrom-Json -ErrorAction Stop
      if ($existing -is [pscustomobject]) {
        foreach ($prop in $existing.PSObject.Properties) {
          $data[$prop.Name] = $prop.Value
        }
      }
    } catch {
      $data = @{}
    }
  }
  $data['autoCompactEnabled'] = $true
  ($data | ConvertTo-Json -Depth 10) | Set-Content -Path $Path -Encoding UTF8
  try {
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
      "$env:USERDOMAIN\$env:USERNAME", 'FullControl', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -Path $Path -AclObject $acl
  } catch { }
}
Set-AutoCompact -Path $ClaudeSettingsFile
Write-Host "Auto-compact enabled in $ClaudeSettingsFile"

Write-Host 'Installed. Run: m3claude'
