# m3claude

One-line installer to run [Claude Code](https://docs.claude.com/en/docs/claude-code) against [TokenRouter](https://tokenrouter.com)'s API with model **MiniMax-M3**. Paste your key once, run anytime.

> Requires the `claude` CLI to already be installed ([instructions](https://docs.claude.com/en/docs/claude-code)).

## Install (one command)

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR-USERNAME/m3claude/main/install.sh | bash
```

Installs a single `m3claude` script into `~/.local/bin`. If that directory isn't on your `PATH`, the installer prints the line to add.

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/YOUR-USERNAME/m3claude/main/install.ps1 | iex
```

Installs `m3claude` into `%LOCALAPPDATA%\Programs\m3claude` and adds it to your user `PATH`. Open a **new** terminal afterward.

> On Windows you can also use the macOS/Linux command above from **Git Bash** or **WSL**.

## Use

First run asks for your TokenRouter API key (hidden input) and saves it:

```bash
m3claude
```

Every run after that just works — same key, no prompt. Any arguments pass straight through to `claude`:

```bash
m3claude "refactor this module"
m3claude --help
```

### Ways to provide the key

The key is resolved in this order:

1. `m3claude config <KEY>` — set it inline, no prompt.
2. The stored config file — set on a previous run.
3. `TOKENROUTER_API_KEY` environment variable — used and saved for next time.
4. Interactive prompt — asked for automatically if none of the above is set.

## Manage your key

```bash
m3claude change-key        # change the stored key (interactive prompt)
m3claude change-key <KEY>  # change the key without a prompt
m3claude reset             # delete the stored key
```

`config`, `set-key`, and `change` are accepted as aliases for `change-key`.

## Update

```bash
m3claude update    # pull the latest version (re-runs the installer)
```

| Platform | Where the key is stored |
| --- | --- |
| macOS / Linux | `~/.config/m3claude/config` (perms `600`) |
| Windows | `%APPDATA%\m3claude\config` (ACL: you only) |

It is stored in plaintext on your machine — anyone with access to your user account can read it. Treat it like any other local credential.

## What it sets

```bash
ANTHROPIC_BASE_URL="https://api.tokenrouter.com/v1"
ANTHROPIC_AUTH_TOKEN="<your TokenRouter API key>"
ANTHROPIC_MODEL="MiniMax-M3"
ANTHROPIC_DEFAULT_OPUS_MODEL="MiniMax-M3"
ANTHROPIC_DEFAULT_SONNET_MODEL="MiniMax-M3"
ANTHROPIC_DEFAULT_HAIKU_MODEL="MiniMax-M3"
CLAUDE_CODE_SUBAGENT_MODEL="MiniMax-M3"
CLAUDE_CODE_EFFORT_LEVEL="max"
```

Then runs: `claude --dangerously-skip-permissions "$@"`

> **Note:** `--dangerously-skip-permissions` lets Claude run tools without per-action approval prompts. Convenient, but it means commands and file edits execute without asking. Use it in a directory you trust.

> **Protocol note:** This wrapper assumes TokenRouter's `/v1` endpoint accepts Anthropic-protocol requests (the format `claude` CLI sends). If it only accepts OpenAI Chat Completions, requests will fail — a translation proxy would be required.

## Uninstall

**macOS / Linux**

```bash
rm ~/.local/bin/m3claude
rm -rf ~/.config/m3claude
```

**Windows (PowerShell)**

```powershell
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\Programs\m3claude"
Remove-Item -Recurse -Force "$env:APPDATA\m3claude"
```

## Credits

Structure and behavior adapted from [RafiulM/deepclaude](https://github.com/RafiulM/deepclaude). License: MIT.
