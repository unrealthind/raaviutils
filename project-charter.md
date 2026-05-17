# raaviutils — Project Charter

> "One curl. Right tool. Done."

---

## What This Is

`raaviutils` is a personal collection of opinionated shell scripts hosted on GitHub and run
directly via `curl`. There is no installer, no package, no system-level footprint beyond what
each individual script explicitly creates. Every script is self-contained, fetched fresh on
demand, and does exactly one thing.

This is a personal toolbox. It is not a framework, not a library, not designed for general
audiences. Defaults are my defaults. Opinions are my opinions. Nothing is configurable that
does not need to be.

---

## What It Is Not

- Not an installed application. Nothing lives in `/usr/local/bin` by default.
- Not a dotfiles manager.
- Not a secret store. No credentials, tokens, API keys, or passwords will ever touch this repo.
  Not in scripts. Not in configs. Not in comments. Not ever.
- Not a dependency on any cloud service, telemetry endpoint, or external API.
- Not designed for other people. Forks welcome; hand-holding is not.

---

## How It Works

Every script in this repo is independently executable via a single `curl` command:

```bash
curl -fsSL https://raw.githubusercontent.com/USER/raaviutils/main/tools/TOOL | bash
```

For tools that take arguments, pass them via `bash -s`:

```bash
curl -fsSL https://raw.githubusercontent.com/USER/raaviutils/main/tools/port-kill | bash -s -- 8080
```

For tools that sit in a pipeline:

```bash
paru -Syu 2>&1 | bash <(curl -fsSL .../tools/cobit)
```

There is no launcher, no central install, no state shared between tools beyond what is
explicitly written to `~/.local/share/raaviutils/` by tools that need persistence.

The repo root contains an index script (`run`) that presents a TUI menu of all available
tools and fetches the selected one on demand. This is optional — every tool works standalone.

```bash
curl -fsSL https://raw.githubusercontent.com/USER/raaviutils/main/run | bash
```

---

## Design Philosophy

Written from the perspective of someone who has watched systems fail in production for over two
decades. The following are not suggestions — they are the load-bearing walls of this project.

### 1. Safety first, convenience second

A tool that does the wrong thing quickly is worse than no tool at all. Every destructive
operation — deletion, overwrite, network share modification, cryptographic key operation,
secure wipe — requires explicit confirmation. The user reads what will happen before it happens.

Principle: **never be the reason someone loses data or access.**

### 2. Fail loudly, fail early, fail cleanly

Every script validates its environment before doing any work:

- Required binaries must be present and reachable.
- Required arguments must exist and be sane.
- Permissions must be appropriate for the task.

If any pre-condition fails: exit immediately, human-readable error to stderr, non-zero exit
code, suggestion for how to fix it. `set -euo pipefail` is the default posture everywhere.

No silent failures. No swallowed errors. No `|| true` appended to hide a problem.

### 3. Principle of least privilege

Scripts request only the access they need. If a tool can work without root, it must do so.
If escalation is needed, it is explicit, scoped, and the user is told exactly why before
being prompted. No script ever runs a blanket `sudo bash`.

### 4. No secrets in code

Scripts that require credentials accept them via environment variable only. The variable
name is documented in the script header. Nothing is hardcoded. The `.gitignore` blocks
every known secret file pattern permanently.

### 5. Idempotency where possible

Running a setup script twice produces the same result as running it once. No duplicate
entries, no broken state. The system is left in a known-good condition every time.

### 6. Graceful degradation

Optional enhancements degrade cleanly. If `bat` is absent, fall back to `cat`. If `gum`
is absent, fall back to `select` and `read`. The core function of every tool must work
with only POSIX utilities and bash 4+. A missing optional binary is never a fatal error.

### 7. Explicit over implicit

No magic. No auto-executing hooks. No curl-pipe-bash dependency installs inside tool
scripts. If a dependency is missing, the tool tells the user what to install and exits.
It does not install things on their behalf without being asked.

### 8. Single responsibility

One script, one job. Shared logic is minimal — this is a collection of standalone scripts,
not a framework. The TUI layer is the only abstraction: all interactive prompts go through
`lib/tui.sh` so the TUI can be swapped without touching tool logic.

---

## Naming and Conventions

### Script naming

`verb-noun` kebab-case: `port-kill`, `strip-meta`, `img-resize`.
The verb describes the action. The noun describes the subject. Ambiguity is a bug.

Package install scripts use `install-` prefix: `install-eza`, `install-docker`, `install-nvim`.

### Function naming

Internal functions use `snake_case` prefixed by the script name to prevent collision:
`port_kill::find_pid`, `smb_manager::list_shares`.

### Variables

- Constants / env vars: `UPPER_SNAKE_CASE`
- Local vars: `lower_snake_case`
- All variables are quoted. Always.
- `local` is used for every variable inside a function. No accidental global pollution.

### Exit codes

| Code | Meaning                              |
|------|--------------------------------------|
| 0    | Success                              |
| 1    | General / unhandled error            |
| 2    | Invalid arguments or usage error     |
| 3    | Missing required dependency          |
| 4    | Permission denied                    |
| 5    | User aborted (declined confirmation) |

### Output conventions

- `stdout`: tool output, safe to pipe.
- `stderr`: all errors, warnings, diagnostics. Always.
- Colour is gated on `[ -t 1 ]`. Piped output is always plain text.
- All user-facing messages are prefixed:
  - `[OK]`    — success
  - `[INFO]`  — informational, no action needed
  - `[WARN]`  — unexpected but non-fatal
  - `[ERROR]` — operation failed
  - `[FATAL]` — unrecoverable, script is exiting

### Script header (required on every tool)

```bash
#!/usr/bin/env bash
# =============================================================================
# tool:        verb-noun
# category:    tools | packages
# description: One sentence. What it does.
# usage:       verb-noun [flags] [args]
# depends:     list of required binaries
# optional:    list of optional binaries that enhance output
# curl:        curl -fsSL https://raw.githubusercontent.com/USER/raaviutils/main/tools/verb-noun | bash
# =============================================================================
set -euo pipefail
```

---

## Tool Inventory

Tools and packages share the same script structure and conventions. Packages are simply
tools whose job is to install software.

### Tools

| Script            | Description                                                         |
|-------------------|---------------------------------------------------------------------|
| `smb-manager`     | Interactively list, mount, unmount, and browse SMB/CIFS shares      |
| `shredder`        | Securely wipe files or directories with confirmation and audit log  |
| `gpg-crypt`       | Encrypt or decrypt files with GPG via interactive key picker        |
| `cobit`           | Pipe logger — tee stdin to stdout and a timestamped log file        |
| `port-kill`       | Find the process listening on a port and kill it                    |
| `yt-grab`         | Download video or audio via yt-dlp with interactive format picker   |
| `vid-compress`    | Compress video to a target size using named ffmpeg presets          |
| `img-convert`     | Bulk convert images between formats                                 |
| `img-resize`      | Bulk resize images to a target resolution or percentage             |
| `rename-batch`    | Batch rename files with pattern preview before any changes commit   |
| `strip-meta`      | Remove EXIF and metadata from images before sharing                 |
| `string-generate` | Generate cryptographically random strings, passphrases, or tokens  |

### Packages

| Script               | Description                                                     |
|----------------------|-----------------------------------------------------------------|
| `install-eza`        | Install eza and inject ll / la / lt aliases into bash and fish  |
| `install-nvim`       | Install latest neovim from official release                     |
| `install-docker`     | Install Docker Engine (distro-aware: Arch / Debian / Fedora)    |
| `install-btop`       | Install btop system monitor                                     |
| `install-fastfetch`  | Install fastfetch and drop in personal config                   |
| `install-bat`        | Install bat and alias cat in bash and fish configs              |

---

## cobit — Design Specification

`cobit` is a pipe logger. It is the simplest tool in the collection and intentionally so.
When any command's output is piped through it, the data passes through to the terminal
unchanged while simultaneously being written to a timestamped log file on disk.

The user sees zero difference in terminal output. The log captures everything.

### Usage

```bash
paru -Syu | cobit
docker build -t myapp . 2>&1 | cobit
sudo dnf update | cobit
```

### What it actually is

`cobit` reads from stdin, writes each line to stdout unchanged, and simultaneously appends
to a log file. It is a `tee` with automatic log file naming. Nothing more.

```bash
# Core behaviour
tee -a "$log_file"
```

### Alias setup (done once, manually or by install-bat)

```bash
# bash  ~/.bashrc
alias cobit='bash <(curl -fsSL https://raw.githubusercontent.com/USER/raaviutils/main/tools/cobit)'

# fish  ~/.config/fish/config.fish
alias cobit 'bash (curl -fsSL https://raw.githubusercontent.com/USER/raaviutils/main/tools/cobit | psub)'
```

### Log location and naming

Logs are written to `~/.local/share/raaviutils/logs/`:

```
~/.local/share/raaviutils/logs/
└── 2026-05-17_03-47-22.log
```

Log header written before any piped content:

```
# raaviutils/cobit
# date: 2026-05-17 03:47:22
# user: username  host: hostname
# ─────────────────────────────────────────────
```

### Flags

- `--list` — list recent logs with date and size, newest first.
- `--view [n]` — open log n (default: most recent) in `bat` or `less`.
- No other flags. Simplicity is the point.

Log directory: `0700`. Log files: `0600`.

---

## shredder — Security Notes

`shredder` wraps `shred` (GNU coreutils) with a confirmation layer and audit trail.

- Prints a clear summary of what will be destroyed before asking for confirmation.
- Requires typing the filename explicitly to confirm — not just pressing `y`.
- Writes an audit entry to `~/.local/share/raaviutils/logs/shredder-audit.log` recording
  filename, size, timestamp, and user. The file is gone; the act of shredding is logged.
- Warns if the filesystem is SSD/NVMe (where `shred` is less effective due to wear-levelling)
  and notes that full-disk encryption is the real solution.
- Does not recurse into directories without an explicit `--recursive` flag.

---

## gpg-crypt — Security Notes

`gpg-crypt` wraps `gpg` with an interactive key picker for encrypt and decrypt.

- Lists available public keys via TUI picker for encryption target selection.
- Never caches passphrases beyond what gpg-agent already handles.
- Does not generate keys — that is `gpg --gen-key`.
- Output files named `<original>.gpg` for encryption, restored to original name on decrypt.
- Confirms the output path before writing.

---

## smb-manager — Security Notes

`smb-manager` manages SMB/CIFS mounts interactively.

- Credentials read from `SMB_USER` / `SMB_PASS` env vars or prompted interactively.
  Never stored in the script or any file committed to git.
- Mount points created under `/mnt/` with explicit confirmation before any mount operation.
- Unmount requires confirmation if the share has open files.
- Does not persist credentials to disk. If persistence is wanted, the user manages their
  own credential file and sets env vars in their shell config — outside this repo.

---

## Dependency Philosophy

A dependency is a liability. Required deps are listed in the script header. If a required dep
is absent, the script tells the user what to install and exits 3. It does not install
automatically. Optional deps fall back silently.

### Universal requirements

- `bash` 4.0+
- `curl`
- `coreutils`

### TUI layer

- `gum` — preferred. Falls back to `select` / `read` / `echo` if absent.
- `fzf` — used by tools that need fuzzy search. Falls back to numbered menu if absent.

### Per-tool dependency matrix

| Script               | Hard deps                      | Optional        |
|----------------------|--------------------------------|-----------------|
| `smb-manager`        | `smbclient`, `mount.cifs`      | `gum`           |
| `shredder`           | `shred`                        | `gum`           |
| `gpg-crypt`          | `gpg`                          | `gum`           |
| `cobit`              | `tee`, `mkdir`                 | `bat`           |
| `port-kill`          | `ss` or `lsof`, `kill`         | `gum`           |
| `yt-grab`            | `yt-dlp`                       | `gum`, `ffmpeg` |
| `vid-compress`       | `ffmpeg`                       | `gum`           |
| `img-convert`        | `ffmpeg` or `imagemagick`      | `gum`           |
| `img-resize`         | `ffmpeg` or `imagemagick`      | `gum`           |
| `rename-batch`       | `mv`                           | `gum`, `bat`    |
| `strip-meta`         | `exiftool`                     | `gum`           |
| `string-generate`    | `openssl` or `/dev/urandom`    | `gum`           |
| `install-eza`        | distro package manager         | —               |
| `install-nvim`       | `curl`, `tar`                  | —               |
| `install-docker`     | distro package manager         | —               |
| `install-btop`       | distro package manager         | —               |
| `install-fastfetch`  | distro package manager         | —               |
| `install-bat`        | distro package manager         | —               |

---

## Repository Structure

```
raaviutils/
├── run                     # TUI index — curl this for interactive menu of all tools
├── tools/
│   ├── smb-manager
│   ├── shredder
│   ├── gpg-crypt
│   ├── cobit
│   ├── port-kill
│   ├── yt-grab
│   ├── vid-compress
│   ├── img-convert
│   ├── img-resize
│   ├── rename-batch
│   ├── strip-meta
│   └── string-generate
├── packages/
│   ├── install-eza
│   ├── install-nvim
│   ├── install-docker
│   ├── install-btop
│   ├── install-fastfetch
│   └── install-bat
├── lib/
│   ├── tui.sh              # TUI adapter (gum → select/read fallback)
│   ├── colors.sh           # ANSI helpers, TTY-gated
│   └── detect.sh           # Distro + package manager detection
└── README.md
```

No `install.sh`. No symlinks into system paths. No shell config modification except by
tools that explicitly do so (`install-eza`, `install-bat`) after user confirmation.

`lib/` scripts are sourced at runtime by each tool via curl:

```bash
_lib="https://raw.githubusercontent.com/USER/raaviutils/main/lib"
source <(curl -fsSL "${_lib}/tui.sh")
source <(curl -fsSL "${_lib}/colors.sh")
source <(curl -fsSL "${_lib}/detect.sh")
```

This keeps every script independently executable with no local install dependency.

---

## Phases

### Phase 1 — Scaffold and proof of concept

Establish `lib/`, the TUI adapter, and prove the curl model end-to-end with two tools.

Deliverables:
- `lib/tui.sh` — gum wrapper with `select`/`read` fallback.
- `lib/colors.sh` — ANSI helpers, TTY-gated.
- `lib/detect.sh` — distro detection, package manager detection, binary checks.
- `run` — index script. Fetches tool list from repo, presents TUI menu, runs selection.
- `tools/string-generate` — first tool. Zero side effects. Proves lib-over-curl works.
- `tools/cobit` — second tool. Proves the pipeline model works.
- `.gitignore` blocking all secret file patterns and log files.

### Phase 2 — Core daily tools

Tools used most often, covering the main capability surface.

Deliverables: `port-kill`, `yt-grab`, `vid-compress`, `img-convert`, `img-resize`,
`rename-batch`, `strip-meta`

Each tool must:
- Pass `shellcheck` with zero warnings.
- Have a `--help` flag that prints usage and exits 0.
- Degrade gracefully on missing optional deps; exit 3 with install hint on missing hard deps.
- Work on Arch, Debian, and Fedora without modification.

### Phase 3 — Sensitive tools and package installers

Tools touching security or system-level operations get extra scrutiny.

Deliverables: `smb-manager`, `shredder`, `gpg-crypt`

Sensitive tools must additionally:
- Require typed confirmation for any destructive action.
- Write an audit log entry for every operation.
- Display a pre-flight summary before executing.
- Be tested on a throwaway environment before merging.

Package scripts: `install-eza`, `install-nvim`, `install-docker`, `install-btop`,
`install-fastfetch`, `install-bat`

Package scripts must:
- Detect the current distro and use the correct package manager.
- Be idempotent — running twice changes nothing if already installed.
- Confirm before modifying any shell config file.

### Phase 4 — Polish and public release

- Full `shellcheck` pass, zero warnings.
- Manual test matrix: Arch (current), Debian 12, Fedora 40 — clean installs.
- README with a copy-pasteable curl command for every tool.
- Security review: secret leakage, unsafe expansion, edge cases.
- First annotated git tag: `v0.1.0`.
- Repo set to public.

---

## Security and Privacy Commitments

Permanent. Not phase goals. Apply from the first commit.

1. **No telemetry.** No usage tracking. No analytics. No pings home. Ever.
2. **No secrets in git.** `.gitignore` enforces this permanently.
3. **No auto-installing deps.** Tools report what is missing and exit. The user installs.
4. **No ambient privilege escalation.** Sudo is scoped, documented, and justified to the
   user before being requested.
5. **Input is untrusted.** Filenames, arguments, and env vars are treated as hostile input.
   Paths are quoted. Injections via crafted filenames are a real threat surface.
6. **Logs stay local.** `~/.local/share/raaviutils/` is in `.gitignore`. Dirs are `0700`,
   files are `0600`. Nothing is transmitted.

---

## Success Criteria

- Any tool runs on a fresh machine with a single curl command and bash.
- Any tool can be read and fully understood in under two minutes.
- No tool has ever silently corrupted data, leaked a secret, or escalated privilege
  unexpectedly.
- The project is still working and maintained two years from now.

---

*Authored by the project owner. Maintained as a living document.*
*Last updated: 2026-05-17*