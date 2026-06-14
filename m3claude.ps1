# m3claude — run Claude Code against TokenRouter's API with model MiniMax-M3 (Windows).
#
# Key resolution order:
#   1. `m3claude config [KEY]`  — set/replace the stored key (inline or prompt)
#   2. stored config file        — set on a previous run
#   3. $env:TOKENROUTER_API_KEY  — used and saved for next time
#   4. interactive prompt        — asks for the key if you haven't included it yet

$ErrorActionPreference = 'Stop'

$ConfigDir  = Join-Path $env:APPDATA 'm3claude'
$ConfigFile = Join-Path $ConfigDir 'config'

function Save-Key([string]$Key) {
  $Key = $Key.Trim()
  if ([string]::IsNullOrEmpty($Key)) {
    Write-Host 'Refusing to save an empty key.'
    return
  }
  New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
  Set-Content -Path $ConfigFile -Value ("TOKENROUTER_API_KEY=" + $Key) -Encoding ASCII
  # Restrict the file to the current user only.
  try {
    $acl  = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
      "$env:USERDOMAIN\$env:USERNAME", 'FullControl', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -Path $ConfigFile -AclObject $acl
  } catch { }
  Write-Host "Key saved to $ConfigFile"
}

function Get-Key {
  if (-not (Test-Path $ConfigFile)) { return $null }
  foreach ($line in Get-Content $ConfigFile) {
    if ($line -like 'TOKENROUTER_API_KEY=*') {
      return $line.Substring('TOKENROUTER_API_KEY='.Length)
    }
  }
  return $null
}

function Invoke-Setup {
  Write-Host ''
  Write-Host '+------------------------------------------+'
  Write-Host '|  m3claude - first-time setup             |'
  Write-Host '+------------------------------------------+'
  Write-Host ''
  Write-Host "Claude Code will run against TokenRouter's API."
  Write-Host 'You only need to enter your key once.'
  Write-Host 'Get a key: https://tokenrouter.com'
  Write-Host ''
  for ($i = 0; $i -lt 3; $i++) {
    $secure = Read-Host -AsSecureString 'TokenRouter API key'
    $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $key    = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $key = $key.Trim()
    if ($key) { Save-Key $key; return }
    Write-Host "Key can't be empty."
  }
  Write-Host 'Aborting after 3 empty attempts.'
  exit 1
}

# --- subcommands -----------------------------------------------------------
if ($args.Count -ge 1) {
  switch -Regex ($args[0]) {
    '^(config|--config|set-key|--set-key|change|--change|change-key|--change-key)$' {
      if ($args.Count -ge 2) { Save-Key $args[1] } else { Invoke-Setup }
      Write-Host "Done. Run 'm3claude' to start."
      exit 0
    }
    '^(reset|--reset)$' {
      if (Test-Path $ConfigFile) { Remove-Item $ConfigFile -Force }
      Write-Host 'Stored key removed.'
      exit 0
    }
    '^(update|--update|upgrade|--upgrade)$' {
      Write-Host 'Updating m3claude to the latest version...'
      irm 'https://raw.githubusercontent.com/atokurn/m3claude/main/install.ps1' | iex
      exit 0
    }
  }
}

# --- resolve the key -------------------------------------------------------
$key = Get-Key

if (-not $key -and $env:TOKENROUTER_API_KEY) {
  $key = $env:TOKENROUTER_API_KEY.Trim()
  Write-Host 'Using TOKENROUTER_API_KEY from environment; saving for next time.'
  Save-Key $key
}

if (-not $key) {
  Invoke-Setup
  $key = Get-Key
}

if (-not $key) {
  Write-Host "No API key available. Run 'm3claude config' to set one."
  exit 1
}

# --- launch ----------------------------------------------------------------
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Write-Host 'claude CLI not found on PATH.'
  Write-Host 'Install Claude Code first: https://docs.claude.com/en/docs/claude-code'
  exit 127
}

$env:ANTHROPIC_BASE_URL            = 'https://api.tokenrouter.com/v1'
$env:ANTHROPIC_AUTH_TOKEN          = $key
$env:ANTHROPIC_MODEL               = 'MiniMax-M3'
$env:ANTHROPIC_DEFAULT_OPUS_MODEL  = 'MiniMax-M3'
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = 'MiniMax-M3'
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL = 'MiniMax-M3'
$env:CLAUDE_CODE_SUBAGENT_MODEL    = 'MiniMax-M3'
$env:CLAUDE_CODE_EFFORT_LEVEL      = 'max'

& claude --dangerously-skip-permissions @args
exit $LASTEXITCODE
