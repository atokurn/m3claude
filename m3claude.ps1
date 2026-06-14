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

# Start the local translation proxy in the background.
# TokenRouter exposes an OpenAI-compatible API; claude CLI speaks Anthropic.
# proxy.py bridges the two. Install: re-run install.ps1, or place proxy.py
# next to this script.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProxyScript = Join-Path $ScriptDir 'proxy.py'

$pythonCmd = $null
foreach ($c in 'python3', 'python', 'py') {
  if (Get-Command $c -ErrorAction SilentlyContinue) { $pythonCmd = $c; break }
}
if (-not $pythonCmd) {
  Write-Host 'python3 not found on PATH.'
  Write-Host 'm3claude needs Python 3 to run the translation proxy.'
  Write-Host 'Install Python 3 from https://python.org and ensure python3 is on PATH.'
  exit 127
}

if (-not (Test-Path $ProxyScript)) {
  Write-Host "proxy.py not found at $ProxyScript"
  Write-Host 'Re-run the installer:'
  Write-Host '  irm https://raw.githubusercontent.com/atokurn/m3claude/main/install.ps1 | iex'
  exit 1
}

$ProxyPortFile = [System.IO.Path]::GetTempFileName()
$ProxyLog      = [System.IO.Path]::GetTempFileName()

# Build env hashtable: inherit parent env, then overlay the proxy vars.
$envForProxy = @{}
[System.Environment]::GetEnvironmentVariables().GetEnumerator() | ForEach-Object {
  try { $envForProxy[$_.Key] = $_.Value.ToString() } catch { }
}
$envForProxy['M3CLAUDE_PORT']       = '0'
$envForProxy['M3CLAUDE_HOST']       = '127.0.0.1'
$envForProxy['M3CLAUDE_PORT_FILE']  = $ProxyPortFile
$envForProxy['M3CLAUDE_UPSTREAM']   = 'https://api.tokenrouter.com'
$envForProxy['TOKENROUTER_API_KEY'] = $key

$proxyProc = Start-Process -FilePath $pythonCmd `
  -ArgumentList @($ProxyScript) `
  -Environment $envForProxy `
  -RedirectStandardOutput $ProxyLog `
  -RedirectStandardError  $ProxyLog `
  -PassThru -NoNewWindow -WindowStyle Hidden

# Wait up to ~5s for the proxy to write its port file.
$proxyPort = $null
for ($i = 0; $i -lt 25; $i++) {
  Start-Sleep -Milliseconds 200
  if ($proxyProc.HasExited) { break }
  if (Test-Path $ProxyPortFile) {
    $raw = Get-Content $ProxyPortFile -ErrorAction SilentlyContinue
    if ($raw) {
      $trimmed = ($raw | Select-Object -First 1).Trim()
      if ($trimmed) { $proxyPort = $trimmed; break }
    }
  }
}

if (-not $proxyPort -or $proxyProc.HasExited) {
  Write-Host 'Translation proxy failed to start. Log:'
  if (Test-Path $ProxyLog) {
    Get-Content $ProxyLog | ForEach-Object { Write-Host "  $_" }
  }
  if (-not $proxyProc.HasExited) { Stop-Process -Id $proxyProc.Id -Force -ErrorAction SilentlyContinue }
  Remove-Item $ProxyPortFile, $ProxyLog -ErrorAction SilentlyContinue
  exit 1
}

# Clean up the proxy on any exit path.
try {
  $env:ANTHROPIC_BASE_URL            = "http://127.0.0.1:$proxyPort"
  $env:ANTHROPIC_AUTH_TOKEN          = $key
  $env:ANTHROPIC_MODEL               = 'MiniMax-M3'
  $env:ANTHROPIC_DEFAULT_OPUS_MODEL  = 'MiniMax-M3'
  $env:ANTHROPIC_DEFAULT_SONNET_MODEL = 'MiniMax-M3'
  $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = 'MiniMax-M3'
  $env:CLAUDE_CODE_SUBAGENT_MODEL    = 'MiniMax-M3'
  $env:CLAUDE_CODE_EFFORT_LEVEL      = 'max'

  & claude --dangerously-skip-permissions @args
  exit $LASTEXITCODE
} finally {
  if ($proxyProc -and -not $proxyProc.HasExited) {
    try { Stop-Process -Id $proxyProc.Id -Force } catch { }
  }
  Remove-Item $ProxyPortFile, $ProxyLog -ErrorAction SilentlyContinue
}
