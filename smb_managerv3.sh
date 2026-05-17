#!/usr/bin/env bash
# smb_manager_v3.1.sh — Manage SMB/CIFS mounts (Create persistent or Unmount/Clean)
#
# v1 → v3 changes:
#   Phase 1 — Bug fixes
#     - Fixed broken JSON separator in do_status (first:=0 → sep="" pattern)
#     - Replaced all /tmp error capture files with inline stderr via 2>&1
#     - Added flock write lock to prevent concurrent fstab corruption
#
#   Phase 2 — Code quality
#     - Extracted write_credfile helper (removed 3x copy-pasted cred blocks)
#     - Kept CREDS_* globals (safe middle — no concurrent subshell risk)
#     - Fixed $USER → $SUDO_USER-aware REAL_USER for chown under sudo
#     - Fixed (( choice )) zero-result trap in do_unmount picker
#     - _check_cifs_kernel: modprobe failure downgraded from ERR to WARN
#     - x-systemd.automount omitted from fstab when systemd is not running
#
#   Phase 3 — UX
#     - fzf wired into create share picker and unmount target picker
#     - Spinner (_spin) for all slow smbclient -gL operations
#     - export/import stubs now print informative messages
#     - help and menu annotate export/import as not yet implemented
#
#   Environment check system
#     - Runs at startup before any command
#     - Detects WSL1, WSL2, Docker, LXC privileged, LXC unprivileged
#     - Prints green/red status board (mount.cifs, CAP_SYS_ADMIN, systemd)
#     - Hard exits on WSL1 and unprivileged LXC with clear fix instructions
#     - Warns on WSL2 (fstab restart caveat) and LXC without systemd
#
# v3 → v3.1 bug fixes:
#   Bug 1 — Box alignment: _row padding was W-4, corrected to W-7; em dash
#            replaced with hyphen to avoid UTF-8 byte/char length mismatch;
#            READY/BLOCKED verdict padding made escape-code-safe
#   Bug 3 — SMB2+ dialect probe was connecting to //$HOST (IPC$) which
#            TrueNAS restricts; now probes //$HOST/$SHARE directly, with a
#            third no-flag fallback to let the server negotiate
#   Bug 4 — User-scope paths ($HOME, credential files) used /root when run
#            with sudo; REAL_HOME now derived via getent passwd from REAL_USER

set -euo pipefail
IFS=$'\n\t'

# ===== UI & logging =====
ts() { date +"%Y-%m-%d %H:%M:%S"; }
INFO() { echo -e "\033[1;34m[$(ts)] [INFO]\033[0m $*"; }
ACTN() { echo -e "\033[1;36m[$(ts)] [ACTION]\033[0m $*"; }
OK() { echo -e "\033[1;32m[$(ts)] [DONE]\033[0m $*"; }
WARN() { echo -e "\033[1;33m[$(ts)] [WARN]\033[0m $*"; }
ERR() { echo -e "\033[1;31m[$(ts)] [ERROR]\033[0m $*" >&2; }
ASK() {
  local v
  read -rp "$1" v
  echo "$v"
}

# ===== deps =====
need() { command -v "$1" >/dev/null 2>&1 || {
  ERR "$1 not found. Install it and re-run."
  exit 1
}; }
need findmnt
need grep
need sed
need awk
need tr
command -v systemd-escape >/dev/null 2>&1 || true
command -v systemctl >/dev/null 2>&1 || true
command -v mountpoint >/dev/null 2>&1 || true
command -v smbclient >/dev/null 2>&1 || {
  ERR "smbclient missing (install samba-client)."
  exit 1
}
command -v mount.cifs >/dev/null 2>&1 || {
  ERR "mount.cifs missing (install cifs-utils)."
  exit 1
}

# ===== basic helpers =====
have() { command -v "$1" >/dev/null 2>&1; }

trim() { sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//' <<<"$1"; }

sanitize_name() {
  local s
  s="$(tr -c 'A-Za-z0-9._-' '_' <<<"$1")"
  s="$(sed -e 's/_\{2,\}/_/g' -e 's/^_//' -e 's/_$//' <<<"$s")"
  printf '%s' "$s"
}

fstab_escape() { sed -e 's/\\/\\\\/g' -e 's/ /\\040/g' -e $'s/\t/\\011/g' <<<"$1"; }

json_escape() { sed 's/\\/\\\\/g; s/"/\\"/g' <<<"${1-}"; }

smb_run() { (smbclient "$@" 2> >(grep -v "Can't load /etc/samba/smb.conf" >&2)); }

list_cifs_mounts() {
  mapfile -t lines < <(findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS | awk '$3=="cifs"{print}')
  if ((${#lines[@]} == 0)); then
    INFO "No CIFS mounts detected."
    return 1
  fi
  INFO "Current CIFS mounts:"
  local i=1
  for L in "${lines[@]}"; do
    local target source
    target=$(awk '{print $1}' <<<"$L")
    source=$(awk '{print $2}' <<<"$L")
    printf "  %2d) TARGET: %s\n      SOURCE: %s\n" "$i" "$target" "$source"
    ((i++))
  done
  return 0
}

find_fstab_line_for_target() {
  local target="$1"
  awk -v tgt="$target" \
    '($0 !~ /^[[:space:]]*#/)&&$2==tgt&&$3=="cifs"{print; exit}' /etc/fstab || true
}

fstab_has_entry() {
  local source="$1" target="$2"
  awk -v src="$source" -v tgt="$target" \
    '($0 !~ /^[[:space:]]*#/)&&$1==src&&$2==tgt&&$3=="cifs"{found=1} END{exit found?0:1}' \
    /etc/fstab
}

# Globals used by creds_parse_file (safe — no concurrent subshell callers)
CREDS_USER=""
CREDS_PASS=""
CREDS_DOMAIN=""
creds_parse_file() {
  local file="$1"
  CREDS_USER=""
  CREDS_PASS=""
  CREDS_DOMAIN=""
  [[ -f "$file" ]] || return 1
  while IFS='=' read -r k v; do
    case "$k" in
    username) CREDS_USER="$v" ;;
    password) CREDS_PASS="$v" ;;
    domain) CREDS_DOMAIN="$v" ;;
    esac
  done < <(grep -E '^(username|password|domain)=' "$file" || true)
  [[ -n "$CREDS_USER" && -n "$CREDS_PASS" ]] || return 1
  return 0
}

# Single credential writer — replaces 3x duplicated blocks from v1
write_credfile() {
  local path="$1" scope="$2" user="$3" pass="$4" domain="$5"
  if [[ "$scope" == "user" ]]; then
    {
      echo "username=$user"
      echo "password=$pass"
      [[ -n "$domain" ]] && echo "domain=$domain"
    } >"$path"
    chmod 600 "$path"
    local _ru="${SUDO_USER:-}"
    [[ -n "$_ru" ]] && chown "$_ru" "$path" || true
  else
    local tf
    tf="$(mktemp)"
    {
      echo "username=$user"
      echo "password=$pass"
      [[ -n "$domain" ]] && echo "domain=$domain"
    } >"$tf"
    chmod 600 "$tf"
    sudo mv "$tf" "$path"
    sudo chown root:root "$path"
  fi
  OK "Credentials saved: $path"
}

# Spinner for slow smbclient operations
_spin() {
  local pid=$1 msg="${2:-Working...}"
  local s='|/-\'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  \033[1;34m%s\033[0m %s" "${s:$((i++ % 4)):1}" "$msg"
    sleep 0.12
  done
  printf "\r\033[2K"
}

# flock guard — only write operations (create, unmount)
_acquire_write_lock() {
  local lf="/tmp/smb_manager_${USER}.lock"
  exec 9>"$lf"
  flock -n 9 || {
    ERR "Another smb_manager write operation is already running."
    exit 1
  }
}

# ===== environment check =====
_detect_env() {
  ENV_NAME="Linux"
  ENV_FATAL=""
  ENV_WARN=""
  HAS_SYSTEMD=0
  HAS_MOUNT_CIFS_BIN=0
  HAS_CAP_SYSADMIN=0
  IS_WSL1=0
  IS_WSL2=0
  IS_LXC=0
  IS_LXC_UNPRIV=0
  IS_DOCKER=0

  command -v mount.cifs >/dev/null 2>&1 && HAS_MOUNT_CIFS_BIN=1

  [[ "$(ps -p 1 -o comm= 2>/dev/null)" == "systemd" ]] && HAS_SYSTEMD=1

  local _capeff
  _capeff=$(awk '/^CapEff:/{print $2}' /proc/self/status 2>/dev/null || echo 0)
  local _cap_dec=$((16#${_capeff:-0}))
  (((_cap_dec >> 21) & 1)) && HAS_CAP_SYSADMIN=1 || true

  # WSL
  if grep -qi microsoft /proc/version 2>/dev/null; then
    if uname -r 2>/dev/null | grep -qi 'WSL2\|microsoft-standard'; then
      IS_WSL2=1
      ENV_NAME="WSL 2"
      ENV_WARN="fstab mounts take effect at WSL restart, not immediately."
    else
      IS_WSL1=1
      ENV_NAME="WSL 1"
      ENV_FATAL="WSL 1 has no CIFS kernel support. Upgrade to WSL 2 or use native Windows SMB access."
    fi
    return
  fi

  # Docker
  if [[ -f /.dockerenv ]] || grep -q 'docker\|containerd' /proc/self/cgroup 2>/dev/null; then
    IS_DOCKER=1
    ENV_NAME="Docker"
    ((HAS_CAP_SYSADMIN)) ||
      ENV_FATAL="Docker container lacks CAP_SYS_ADMIN. Run with --cap-add SYS_ADMIN or mount on the host."
    return
  fi

  # LXC
  local _virt=""
  if have systemd-detect-virt; then
    _virt=$(systemd-detect-virt --container 2>/dev/null || true)
  fi
  if [[ "$_virt" == "lxc" ]] ||
    grep -q 'lxc' /proc/self/cgroup 2>/dev/null ||
    [[ -f /run/host/container-manager ]]; then
    IS_LXC=1
    if ((HAS_CAP_SYSADMIN)); then
      ENV_NAME="LXC (privileged)"
      ((HAS_SYSTEMD)) ||
        ENV_WARN="systemd not running — x-systemd.automount options will be omitted from fstab."
    else
      IS_LXC_UNPRIV=1
      ENV_NAME="LXC (unprivileged)"
      ENV_FATAL="Unprivileged LXC lacks CAP_SYS_ADMIN. mount.cifs cannot work.\nFix: add 'lxc.cap.keep: sys_admin' to the container config, or mount on the host and bind-mount in."
    fi
    return
  fi
}

# Bug 1 fix: correct padding math, hyphen title (no UTF-8 byte/char mismatch),
# escape-code-safe verdict line
_show_env_check() {
  local W=44
  local GRN="\033[1;32m" RED="\033[1;31m" YLW="\033[1;33m"
  local BLU="\033[1;34m" NC="\033[0m"
  local BAR
  BAR="$(printf '─%.0s' $(seq 1 $W))"

  _row() {
    local dot="$1" label="$2" value="$3"
    local pad=$((W - 7 - ${#label} - ${#value}))
    ((pad < 1)) && pad=1
    local spaces
    spaces=$(printf '%*s' "$pad" '')
    printf "  ${BLU}│${NC}  ${dot}  %s%s%s  ${BLU}│${NC}\n" \
      "$label" "$spaces" "$value"
  }
  _divider() { printf "  ${BLU}├${BAR}┤${NC}\n"; }
  _blank() { printf "  ${BLU}│${NC}%*s${BLU}│${NC}\n" "$W" ""; }

  printf "\n"
  printf "  ${BLU}┌${BAR}┐${NC}\n"

  local title="  smb_manager - environment check"
  local tpad=$((W - ${#title} - 2))
  ((tpad < 1)) && tpad=1
  printf "  ${BLU}│${NC}%s%*s  ${BLU}│${NC}\n" "$title" "$tpad" ""
  _divider

  local plat_pad=$((W - 20 - ${#ENV_NAME}))
  ((plat_pad < 1)) && plat_pad=1
  printf "  ${BLU}│${NC}    Platform      %s%*s  ${BLU}│${NC}\n" \
    "$ENV_NAME" "$plat_pad" ""
  _blank

  if ((HAS_MOUNT_CIFS_BIN)); then
    _row "${GRN}●${NC}" "mount.cifs   " "available"
  else
    _row "${RED}●${NC}" "mount.cifs   " "missing  "
  fi

  if ((HAS_CAP_SYSADMIN)); then
    _row "${GRN}●${NC}" "CAP_SYS_ADMIN" "granted  "
  else
    _row "${RED}●${NC}" "CAP_SYS_ADMIN" "denied   "
  fi

  if ((HAS_SYSTEMD)); then
    _row "${GRN}●${NC}" "systemd      " "running  "
  else
    _row "${YLW}●${NC}" "systemd      " "not running"
  fi

  if ((IS_WSL2)); then
    _row "${YLW}●${NC}" "fstab mounts " "restart needed"
  fi

  _blank
  _divider

  local verdict_text verdict_dot
  if [[ -z "$ENV_FATAL" ]]; then
    verdict_dot="${GRN}● READY  ${NC}"
    verdict_text="this system is supported"
  else
    verdict_dot="${RED}● BLOCKED${NC}"
    verdict_text="will not work here      "
  fi
  local vpad=$((W - 15 - ${#verdict_text}))
  ((vpad < 1)) && vpad=1
  printf "  ${BLU}│${NC}  %b  %s%*s  ${BLU}│${NC}\n" \
    "$verdict_dot" "$verdict_text" "$vpad" ""

  printf "  ${BLU}└${BAR}┘${NC}\n\n"
}

check_environment() {
  _detect_env
  _show_env_check

  if [[ -n "$ENV_WARN" ]]; then
    WARN "$ENV_WARN"
    echo
  fi

  if [[ -n "$ENV_FATAL" ]]; then
    ERR "$ENV_FATAL"
    exit 1
  fi
}

# ===== SUBCOMMAND SCAFFOLD & FLAGS =====
HAS_FZF=$([ -n "${NO_FZF:-}" ] && echo 0 || (have fzf && echo 1 || echo 0))
HAS_JQ=$([ -n "${NO_JQ:-}" ] && echo 0 || (have jq && echo 1 || echo 0))
HAS_NOTIFY=$([ -n "${NO_NOTIFY:-}" ] && echo 0 || (have notify-send && echo 1 || echo 0))
HAS_DIALOG=$([ -n "${NO_DIALOG:-}" ] && echo 0 || (have dialog || have whiptail && echo 1 || echo 0))
HAS_TIMEOUT=$([ -n "${NO_TIMEOUT:-}" ] && echo 0 || (have timeout && echo 1 || echo 0))
HAS_PARALLEL=$([ -n "${NO_PARALLEL:-}" ] && echo 0 || (have parallel && echo 1 || echo 0))

FLAG_YES=0
FLAG_JSON=0
FLAG_QUIET=0
FLAG_DEBUG=0

usage() {
  cat <<'USAGE'
smb_manager_v3.1.sh [global flags] <command> [args]

Commands:
  create        Create a persistent mount (per-share creds, fstab safe edits)
  unmount       Unmount & clean (fstab, dir, creds prompt)
  status        Show current CIFS mounts (table or JSON)
  verify        Run preflight: DNS/port 445, smbclient probe, time skew
  health        Check all mounts: state, space, rw sanity test
  export        [not yet implemented] Export mounts/profiles to JSON
  import        [not yet implemented] Import mounts/profiles from JSON
  help          Show this help

Global flags:
  --yes         Assume "yes" to confirmations
  --json        Machine-readable output
  --quiet       Minimal human output
  --debug       Verbose diagnostics
  --no-fzf|--no-jq|--no-notify|--no-dialog|--no-timeout|--no-parallel

Examples:
  smb_manager_v3.1.sh status
  smb_manager_v3.1.sh --yes create
USAGE
}

GLOBAL_ARGS=()
CMD=""
for arg in "$@"; do
  case "$arg" in
  create | unmount | status | verify | health | export | import | help) CMD="$arg" ;;
  --yes) FLAG_YES=1 ;;
  --json) FLAG_JSON=1 ;;
  --quiet) FLAG_QUIET=1 ;;
  --debug) FLAG_DEBUG=1 ;;
  --no-fzf) HAS_FZF=0 ;;
  --no-jq) HAS_JQ=0 ;;
  --no-notify) HAS_NOTIFY=0 ;;
  --no-dialog) HAS_DIALOG=0 ;;
  --no-timeout) HAS_TIMEOUT=0 ;;
  --no-parallel) HAS_PARALLEL=0 ;;
  -h | --help) CMD="help" ;;
  *) GLOBAL_ARGS+=("$arg") ;;
  esac
done

jout() { if ((FLAG_JSON)); then printf '%s\n' "$1"; fi; }
hlog() { ((FLAG_QUIET)) || INFO "$@"; }
dlog() { ((FLAG_DEBUG)) && WARN "[debug] $*"; }
notify() { ((HAS_NOTIFY)) && notify-send "SMB Manager" "$*" || true; }

# ===== UNMOUNT / CLEAN =====
do_unmount() {
  mapfile -t lines < <(findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS | awk '$3=="cifs"{print}')
  if ((${#lines[@]} == 0)); then
    WARN "No CIFS mounts to unmount."
    return
  fi

  INFO "Select a CIFS mount to unmount:"
  local TARGETS=() SOURCES=()
  local i=1
  for L in "${lines[@]}"; do
    local target source
    target=$(awk '{print $1}' <<<"$L")
    source=$(awk '{print $2}' <<<"$L")
    TARGETS+=("$target")
    SOURCES+=("$source")
    ((i++))
  done

  local MOUNT_POINT="" SOURCE="" idx=0
  if ((HAS_FZF)); then
    local fzf_lines=()
    for i in "${!TARGETS[@]}"; do
      fzf_lines+=("$(printf '%s  →  %s' "${TARGETS[$i]}" "${SOURCES[$i]}")")
    done
    local picked
    picked=$(printf '%s\n' "${fzf_lines[@]}" |
      fzf --prompt="Unmount > " --height=40% --reverse --no-multi \
        --header="Select a CIFS mount (ESC to cancel)" || true)
    [[ -z "$picked" ]] && {
      INFO "Canceled."
      return
    }
    for i in "${!fzf_lines[@]}"; do
      [[ "${fzf_lines[$i]}" == "$picked" ]] && idx=$i && break
    done
  else
    i=1
    for t in "${TARGETS[@]}"; do
      printf "  %2d) TARGET: %s\n      SOURCE: %s\n" "$i" "$t" "${SOURCES[$((i - 1))]}"
      ((i++))
    done
    local choice
    while :; do
      choice=$(ASK "Choose [1-${#TARGETS[@]}] (or 0 to cancel): ")
      [[ "$choice" =~ ^[0-9]+$ ]] || {
        WARN "Enter a number."
        continue
      }
      if ((choice == 0)); then
        INFO "Canceled."
        return
      elif ((choice >= 1 && choice <= ${#TARGETS[@]})); then
        break
      else
        WARN "Out of range."
      fi
    done
    idx=$((choice - 1))
  fi

  MOUNT_POINT="${TARGETS[$idx]}"
  SOURCE="${SOURCES[$idx]}"
  OK "Selected:\n   TARGET: $MOUNT_POINT\n   SOURCE: $SOURCE"

  if command -v systemd-escape >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
    local ub
    ub=$(systemd-escape -p "$MOUNT_POINT")
    ACTN "Stopping potential systemd units: ${ub}.automount / ${ub}.mount"
    sudo systemctl stop "${ub}.automount" >/dev/null 2>&1 || true
    sudo systemctl stop "${ub}.mount" >/dev/null 2>&1 || true
    OK "Systemd units stopped (if present)."
  fi

  local mounted=0
  if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    mounted=1
  elif findmnt -no TARGET --target "$MOUNT_POINT" >/dev/null 2>&1; then
    mounted=1
  fi

  if ((mounted)); then
    ACTN "Unmounting: $MOUNT_POINT"
    local _uerr=""
    if _uerr=$(sudo umount "$MOUNT_POINT" 2>&1); then
      OK "Unmounted."
    else
      if grep -qi 'not mounted' <<<"$_uerr"; then
        INFO "Already unmounted. Continuing."
      else
        WARN "Unmount failed: $_uerr"
        local ans
        ans=$(ASK "Try lazy unmount (-l)? [y/N]: ")
        if [[ "$ans" =~ ^[Yy]$ ]]; then
          ACTN "Lazy unmount: umount -l $MOUNT_POINT"
          local _luerr=""
          if _luerr=$(sudo umount -l "$MOUNT_POINT" 2>&1); then
            OK "Lazy unmounted."
          else
            if grep -qi 'not mounted' <<<"$_luerr"; then
              INFO "Already unmounted. Continuing."
            else
              ERR "Lazy unmount failed: $_luerr"
              return
            fi
          fi
        else
          ERR "Leaving mount in place."
          return
        fi
      fi
    fi
  else
    INFO "Mount point not currently mounted (automount idle). Continuing."
  fi

  local FSTAB_LINE
  FSTAB_LINE="$(find_fstab_line_for_target "$MOUNT_POINT")"
  if [[ -n "$FSTAB_LINE" ]]; then
    echo
    INFO "Matching /etc/fstab entry:"
    echo "    $FSTAB_LINE"
    local rm_ans
    rm_ans=$(ASK "Remove this line from /etc/fstab? [y/N]: ")
    if [[ "$rm_ans" =~ ^[Yy]$ ]]; then
      local BAK="/etc/fstab.bak.$(date +%s)"
      ACTN "Backup /etc/fstab → $BAK"
      sudo cp /etc/fstab "$BAK"
      OK "Backup created."
      local mp="$MOUNT_POINT"
      ACTN "Removing fstab line for: $mp"
      sudo awk -v tgt="$mp" \
        '($0 ~ /^[[:space:]]*#/){print; next} !($2==tgt && $3=="cifs")' \
        /etc/fstab | sudo tee /etc/fstab.tmp >/dev/null
      sudo mv /etc/fstab.tmp /etc/fstab
      OK "Removed from /etc/fstab."
      command -v systemctl >/dev/null 2>&1 && {
        ACTN "Reloading systemd"
        sudo systemctl daemon-reload || true
        OK "Reloaded."
      }
    else
      INFO "Kept /etc/fstab unchanged."
    fi
  else
    INFO "No matching /etc/fstab entry for: $MOUNT_POINT"
  fi

  local deldir
  deldir=$(ASK "Delete mount directory ($MOUNT_POINT)? [y/N]: ")
  if [[ "$deldir" =~ ^[Yy]$ ]]; then
    ACTN "Deleting directory: $MOUNT_POINT"
    local _rmerr=""
    if _rmerr=$(rmdir "$MOUNT_POINT" 2>&1); then
      OK "Directory removed."
    else
      WARN "rmdir failed: $_rmerr"
      local rmr
      rmr=$(ASK "Recursive delete with sudo rm -rf? [y/N]: ")
      if [[ "$rmr" =~ ^[Yy]$ ]]; then
        ACTN "sudo rm -rf $MOUNT_POINT"
        sudo rm -rf "$MOUNT_POINT"
        OK "Force-removed."
      else
        INFO "Directory left intact."
      fi
    fi
  else
    INFO "Directory kept."
  fi

  local CRED_PATH=""
  if [[ -n "${FSTAB_LINE:-}" ]]; then
    CRED_PATH=$(awk -F',' \
      '{for(i=1;i<=NF;i++){ if($i ~ /credentials=/){ sub(/.*credentials=/,"",$i); print $i }}}' \
      <<<"$FSTAB_LINE")
  fi
  if [[ -n "$CRED_PATH" && -f "$CRED_PATH" ]]; then
    echo
    INFO "Credentials file appears to be: $CRED_PATH"
    local delc
    delc=$(ASK "Delete credentials file? [y/N]: ")
    if [[ "$delc" =~ ^[Yy]$ ]]; then
      ACTN "Deleting credentials: $CRED_PATH"
      rm -f "$CRED_PATH" 2>/dev/null || {
        WARN "Trying sudo..."
        sudo rm -f "$CRED_PATH"
      }
      OK "Credentials file deleted."
    else
      INFO "Credentials kept."
    fi
  else
    INFO "No obvious credentials file to remove."
  fi

  OK "Unmount/cleanup complete."
}

# ===== CREATE MOUNT =====
do_create() {
  local HOST=""
  while [[ -z "$HOST" ]]; do HOST=$(ASK "Enter SMB host (IP or hostname): "); done
  INFO "Target host: $HOST"

  INFO "Trying anonymous share listing on //$HOST ..."
  local LIST_OUT="" PROTO_DETECT=""
  local TMPU="" TMPP=""

  local _lo_tmp
  _lo_tmp=$(mktemp)
  smb_run -gL "//$HOST" -N >"$_lo_tmp" 2>/dev/null &
  local _pid=$!
  _spin "$_pid" "Listing shares on //$HOST (anonymous)..."
  if wait "$_pid"; then
    LIST_OUT=$(cat "$_lo_tmp")
    rm -f "$_lo_tmp"
    PROTO_DETECT="auto"
    OK "Anonymous listing succeeded."
  else
    rm -f "$_lo_tmp"
    WARN "Anonymous listing blocked (likely good)."

    local used_existing_for_listing=0

    # Scan for any existing per-share credential files for this host
    # REAL_HOME not computed yet at this point — derive inline for the scan
    local _scan_home="$HOME"
    [[ -n "${SUDO_USER:-}" ]] &&
      _scan_home=$(getent passwd "$SUDO_USER" | cut -d: -f6 2>/dev/null || echo "$HOME")

    local _existing_creds=()
    local _f
    for _f in "$_scan_home/.smbcredentials-${HOST}-"* \
      "/root/.smbcredentials-${HOST}-"*; do
      [[ -f "$_f" ]] || continue
      local _dup=0
      local _e
      for _e in "${_existing_creds[@]:-}"; do
        [[ "$_e" == "$_f" ]] && _dup=1 && break
      done
      ((_dup)) || _existing_creds+=("$_f")
    done

    if ((${#_existing_creds[@]})); then
      INFO "Existing credentials found for $HOST:"
      local _chosen_cred=""

      if ((HAS_FZF)); then
        local _fzf_cred_lines=()
        for _f in "${_existing_creds[@]}"; do
          local _u
          _u=$(awk -F= '/^username/{print $2; exit}' "$_f" 2>/dev/null || echo "?")
          _fzf_cred_lines+=("$(printf 'user: %-20s  %s' "$_u" "$_f")")
        done
        local _picked_line
        _picked_line=$(printf '%s\n' "${_fzf_cred_lines[@]}" "[enter temporary credentials]" |
          fzf --prompt="Credentials > " --height=40% --reverse --no-multi \
            --header="Select existing credentials for listing (ESC = skip)" || true)
        if [[ -n "$_picked_line" &&
          "$_picked_line" != "[enter temporary credentials]" ]]; then
          _chosen_cred="${_picked_line##*  }"
        fi
      else
        local _ci=1
        for _f in "${_existing_creds[@]}"; do
          local _u
          _u=$(awk -F= '/^username/{print $2; exit}' "$_f" 2>/dev/null || echo "?")
          printf "  %2d) user: %-20s  %s\n" "$_ci" "$_u" "$_f"
          ((_ci++))
        done
        echo "   0) Enter temporary credentials instead"
        local _cpick
        while :; do
          _cpick=$(ASK "Choose [1-${#_existing_creds[@]}] or 0 for new: ")
          [[ "$_cpick" =~ ^[0-9]+$ ]] || {
            WARN "Enter a number."
            continue
          }
          if ((_cpick == 0)); then
            break
          elif ((_cpick >= 1 && _cpick <= ${#_existing_creds[@]})); then
            _chosen_cred="${_existing_creds[$((_cpick - 1))]}"
            break
          else
            WARN "Out of range."
          fi
        done
      fi

      if [[ -n "$_chosen_cred" ]] && creds_parse_file "$_chosen_cred"; then
        local _lo_tmp2
        _lo_tmp2=$(mktemp)
        { smb_run -gL "//$HOST" -m SMB3 -U "${CREDS_USER}%${CREDS_PASS}" \
          >"$_lo_tmp2" 2>/dev/null ||
          smb_run -gL "//$HOST" -m SMB2 -U "${CREDS_USER}%${CREDS_PASS}" \
            >"$_lo_tmp2" 2>/dev/null; } &
        local _pid2=$!
        _spin "$_pid2" "Listing shares (existing creds)..."
        if wait "$_pid2"; then
          LIST_OUT=$(cat "$_lo_tmp2")
          rm -f "$_lo_tmp2"
          PROTO_DETECT="SMB3"
          OK "Share listing with existing creds succeeded."
          # Propagate into TMPU/TMPP so permanent cred section can offer reuse
          TMPU="$CREDS_USER"
          TMPP="$CREDS_PASS"
          used_existing_for_listing=1
        else
          rm -f "$_lo_tmp2"
          WARN "Listing failed with selected credentials. Falling through to temporary creds."
        fi
      fi
    fi

    if ((!used_existing_for_listing)); then
      TMPU=$(ASK "Temporary username for listing (leave blank to skip): ")
      if [[ -n "$TMPU" ]]; then
        read -rsp "Temporary password for $TMPU: " TMPP
        echo
        local _lo_tmp3
        _lo_tmp3=$(mktemp)
        smb_run -gL "//$HOST" -m SMB3 -U "${TMPU}%${TMPP}" >"$_lo_tmp3" 2>/dev/null &
        local _pid3=$!
        _spin "$_pid3" "Listing shares via SMB3..."
        if wait "$_pid3"; then
          LIST_OUT=$(cat "$_lo_tmp3")
          rm -f "$_lo_tmp3"
          PROTO_DETECT="SMB3"
          OK "Share listing via SMB3 succeeded."
        else
          rm -f "$_lo_tmp3"
          local _lo_tmp4
          _lo_tmp4=$(mktemp)
          smb_run -gL "//$HOST" -m SMB2 -U "${TMPU}%${TMPP}" >"$_lo_tmp4" 2>/dev/null &
          local _pid4=$!
          _spin "$_pid4" "Listing shares via SMB2..."
          if wait "$_pid4"; then
            LIST_OUT=$(cat "$_lo_tmp4")
            rm -f "$_lo_tmp4"
            PROTO_DETECT="SMB2"
            OK "Share listing via SMB2 succeeded."
          else
            rm -f "$_lo_tmp4"
            ERR "Could not list shares (even with creds). You can still type a share manually."
          fi
        fi
      fi
    fi
  fi

  local SHARES=()
  if [[ -n "${LIST_OUT:-}" ]]; then
    while IFS='|' read -r typ name _rest; do
      [[ "$typ" == "Disk" ]] || continue
      name="$(trim "$name")"
      [[ "$name" == "IPC$" || "$name" == "ADMIN$" || "$name" == "print$" ]] && continue
      SHARES+=("$name")
    done <<<"$LIST_OUT"
  fi

  local SHARE=""
  if ((${#SHARES[@]})); then
    INFO "Shares found on //$HOST:"
    if ((HAS_FZF)); then
      local fzf_opts=("${SHARES[@]}" "[enter manually]")
      local picked
      picked=$(printf '%s\n' "${fzf_opts[@]}" |
        fzf --prompt="Share > " --height=40% --reverse --no-multi \
          --header="Select a share on //$HOST" || true)
      [[ -z "$picked" ]] && {
        INFO "Canceled."
        return
      }
      if [[ "$picked" == "[enter manually]" ]]; then
        SHARE=$(ASK "Type the share name (case-sensitive): ")
        SHARE="$(trim "$SHARE")"
      else
        SHARE="$(trim "$picked")"
      fi
    else
      local i
      for i in "${!SHARES[@]}"; do printf "  %2d) %s\n" $((i + 1)) "${SHARES[$i]}"; done
      echo "   0) Enter share name manually"
      local pick
      while :; do
        pick=$(ASK "Choose a share number (or 0 to type manually): ")
        if [[ "$pick" =~ ^[0-9]+$ ]] && ((pick >= 0 && pick <= ${#SHARES[@]})); then
          if ((pick == 0)); then
            SHARE=$(ASK "Type the share name (case-sensitive): ")
            SHARE="$(trim "$SHARE")"
          else
            SHARE="${SHARES[$((pick - 1))]}"
            SHARE="$(trim "$SHARE")"
          fi
          break
        else
          WARN "Invalid choice."
        fi
      done
    fi
  else
    SHARE=$(ASK "No shares listed. Type share name to mount (case-sensitive): ")
    SHARE="$(trim "$SHARE")"
  fi
  [[ -z "$SHARE" ]] && {
    ERR "No share selected."
    return
  }
  OK "Selected share: //${HOST}/${SHARE}"

  local scope=""
  while :; do
    local s
    s=$(ASK "Mount for (u)ser-only or (s)ystem-wide? [u/s]: ")
    case "$s" in
    u | U)
      scope="user"
      break
      ;;
    s | S)
      scope="system"
      break
      ;;
    *) WARN "Enter 'u' or 's'." ;;
    esac
  done
  OK "Scope: $scope"

  # Bug 4 fix: derive real user and home from SUDO_USER, not $HOME / $USER
  local REAL_USER="${SUDO_USER:-$USER}"
  local REAL_GROUP
  REAL_GROUP=$(id -gn "$REAL_USER")
  local REAL_HOME
  REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6 2>/dev/null || echo "$HOME")

  local DEFAULT_BASE
  [[ "$scope" == "user" ]] && DEFAULT_BASE="$REAL_HOME/mnt" || DEFAULT_BASE="/mnt"
  INFO "Default mount path: $DEFAULT_BASE/$HOST/$SHARE"

  local MOUNT_DIR
  while :; do
    local dc
    dc=$(ASK "Use default path or custom? ([d]efault / [c]ustom): ")
    case "$dc" in
    d | D)
      MOUNT_DIR="$DEFAULT_BASE/$HOST/$SHARE"
      break
      ;;
    c | C)
      MOUNT_DIR=$(ASK "Enter full mount path (absolute): ")
      [[ "$MOUNT_DIR" = /* ]] || {
        WARN "Provide an absolute path."
        continue
      }
      break
      ;;
    *) WARN "Enter d or c." ;;
    esac
  done

  ACTN "Create directory: $MOUNT_DIR"
  if [[ "$scope" == "user" ]]; then
    mkdir -p "$MOUNT_DIR"
    chown "$REAL_USER":"$REAL_GROUP" "$MOUNT_DIR"
  else
    sudo mkdir -p "$MOUNT_DIR"
    sudo chown root:root "$MOUNT_DIR"
  fi
  OK "Directory ready: $MOUNT_DIR"

  local SHARE_SAFE
  SHARE_SAFE="$(sanitize_name "$(trim "$SHARE")")"
  local CREDFILE HOST_CRED

  # Bug 4 fix: use REAL_HOME for credential paths, not $HOME
  if [[ "$scope" == "user" ]]; then
    CREDFILE="$REAL_HOME/.smbcredentials-${HOST}-${SHARE_SAFE}"
    HOST_CRED="$REAL_HOME/.smbcredentials-$HOST"
  else
    CREDFILE="/root/.smbcredentials-${HOST}-${SHARE_SAFE}"
    HOST_CRED="/root/.smbcredentials-$HOST"
  fi

  if [[ -f "$CREDFILE" ]]; then
    INFO "Per-share credentials already exist: $CREDFILE"
  else
    local _cred_written=0

    # Offer to reuse listing credentials (typed or selected from stored) as permanent
    if [[ -n "$TMPU" ]]; then
      INFO "Credentials used for listing — user: $TMPU"
      local _reuse_tmp
      _reuse_tmp=$(ASK "Save these as the permanent credentials for this share? [Y/n]: ")
      if [[ ! "$_reuse_tmp" =~ ^[Nn]$ ]]; then
        local SMB_DOMAIN=""
        SMB_DOMAIN=$(ASK "SMB domain for $TMPU (leave blank if none): ")
        ACTN "Write credentials file: $CREDFILE"
        write_credfile "$CREDFILE" "$scope" "$TMPU" "$TMPP" "$SMB_DOMAIN"
        _cred_written=1
      fi
    fi

    if ((!_cred_written)); then
      if [[ -f "$HOST_CRED" ]]; then
        local use_copy
        use_copy=$(ASK "Use existing host creds from $HOST_CRED for this share? [y/N]: ")
        if [[ "$use_copy" =~ ^[Yy]$ ]]; then
          ACTN "Copying $HOST_CRED → $CREDFILE"
          if [[ "$scope" == "user" ]]; then
            cp "$HOST_CRED" "$CREDFILE"
            chmod 600 "$CREDFILE"
          else
            sudo cp "$HOST_CRED" "$CREDFILE"
            sudo chmod 600 "$CREDFILE"
            sudo chown root:root "$CREDFILE"
          fi
          OK "Per-share credentials ready: $CREDFILE"
          _cred_written=1
        fi
      fi
    fi

    if ((!_cred_written)); then
      INFO "Enter credentials to save securely (per-share)."
      local SMB_USER SMB_PASS SMB_DOMAIN
      SMB_USER=$(ASK "SMB username: ")
      read -rsp "SMB password: " SMB_PASS
      echo
      SMB_DOMAIN=$(ASK "SMB domain (leave blank if none): ")
      ACTN "Write credentials file: $CREDFILE"
      write_credfile "$CREDFILE" "$scope" "$SMB_USER" "$SMB_PASS" "$SMB_DOMAIN"
    fi
  fi

  local SMB_USER="" SMB_PASS="" SMB_DOMAIN=""
  if creds_parse_file "$CREDFILE"; then
    SMB_USER="$CREDS_USER"
    SMB_PASS="$CREDS_PASS"
    SMB_DOMAIN="$CREDS_DOMAIN"
  fi

  # Bug 3 fix: probe //$HOST/$SHARE (not IPC$) so TrueNAS auth works correctly
  local SMB_VERS=""
  if [[ "$PROTO_DETECT" == "SMB3" || "$PROTO_DETECT" == "auto" ]]; then
    SMB_VERS="3.1.1"
  elif [[ "$PROTO_DETECT" == "SMB2" ]]; then
    SMB_VERS="2.1"
  else
    INFO "Verifying SMB version via quick probe on //$HOST/$SHARE ..."
    if [[ -n "$SMB_USER" && -n "$SMB_PASS" ]] &&
      smb_run -m SMB3 -U "${SMB_USER}%${SMB_PASS}" \
        "//$HOST/$SHARE" -c quit >/dev/null 2>&1; then
      SMB_VERS="3.1.1"
    elif [[ -n "$SMB_USER" && -n "$SMB_PASS" ]] &&
      smb_run -m SMB2 -U "${SMB_USER}%${SMB_PASS}" \
        "//$HOST/$SHARE" -c quit >/dev/null 2>&1; then
      SMB_VERS="2.1"
    elif [[ -n "$SMB_USER" && -n "$SMB_PASS" ]] &&
      smb_run -U "${SMB_USER}%${SMB_PASS}" \
        "//$HOST/$SHARE" -c quit >/dev/null 2>&1; then
      WARN "Explicit SMB3/SMB2 probe failed — letting server negotiate version."
      SMB_VERS="3.0"
    else
      ERR "Cannot connect to //$HOST/$SHARE. Check host, share name, and credentials."
      return
    fi
  fi
  OK "Using SMB vers=${SMB_VERS}"

  local IDLE_OPT=""
  if ((HAS_SYSTEMD)); then
    local en
    en=$(ASK "Enable auto-unmount when idle? [y/N]: ")
    if [[ "$en" =~ ^[Yy]$ ]]; then
      local t
      t=$(ASK "Idle timeout seconds (default 300): ")
      [[ -z "$t" ]] && t=300
      if [[ "$t" =~ ^[0-9]+$ ]] && ((t > 0)); then
        IDLE_OPT=",x-systemd.idle-timeout=${t}"
        OK "Idle unmount: ${t}s"
      else
        WARN "Invalid timeout; skipping."
      fi
    else
      INFO "Idle unmount disabled."
    fi
  else
    INFO "systemd not running — skipping idle-timeout option."
  fi

  local SRC="//${HOST}/${SHARE}" SRC_ESC TGT_ESC
  SRC_ESC="$(fstab_escape "$SRC")"
  TGT_ESC="$(fstab_escape "$MOUNT_DIR")"

  local UID_VAL
  UID_VAL=$(id -u "$REAL_USER")
  local GID_VAL
  GID_VAL=$(id -g "$REAL_USER")

  local AUTOMOUNT_OPT=""
  ((HAS_SYSTEMD)) && AUTOMOUNT_OPT=",x-systemd.automount"

  local OPTS="_netdev${AUTOMOUNT_OPT}${IDLE_OPT},nofail,credentials=${CREDFILE},vers=${SMB_VERS},uid=${UID_VAL},gid=${GID_VAL},file_mode=0644,dir_mode=0755"
  local LINE="${SRC_ESC} ${TGT_ESC} cifs ${OPTS} 0 0"

  local BAK="/etc/fstab.bak.$(date +%s)"
  ACTN "Backup /etc/fstab → $BAK"
  sudo cp /etc/fstab "$BAK"
  OK "Backup created."

  if fstab_has_entry "$SRC_ESC" "$TGT_ESC"; then
    WARN "Matching fstab entry already exists; skipping append."
  else
    ACTN "Append to /etc/fstab:"
    echo "      $LINE"
    echo "$LINE" | sudo tee -a /etc/fstab >/dev/null
    OK "fstab updated."
  fi

  ACTN "Mount: $MOUNT_DIR"
  local _merr=""
  if _merr=$(sudo mount "$MOUNT_DIR" 2>&1); then
    OK "Mounted: $MOUNT_DIR"
    mount | grep --color=never " ${MOUNT_DIR} " || true
  else
    WARN "Mount failed: $_merr"
    WARN "Try: sudo mount -a"
    return
  fi

  if ((IS_WSL2)); then
    INFO "Note: on WSL 2, fstab mounts are not re-applied automatically. Run 'sudo mount -a' or restart WSL to re-mount after reboot."
  fi

  INFO "Create-mount flow complete."
}

# ===== VERIFY / SELF-TESTS =====
VER_JSON_ITEMS=()
_add_result() {
  local status="$1"
  shift
  local msg="$*"
  local color_ok="\033[1;32m" color_bad="\033[1;31m" color_wrn="\033[1;33m" nc="\033[0m"
  local tag
  case "$status" in
  OK) tag="${color_ok}OK${nc}" ;;
  WARN) tag="${color_wrn}WARN${nc}" ;;
  ERR) tag="${color_bad}ERR${nc}" ;;
  *) tag="$status" ;;
  esac
  ((FLAG_JSON)) || echo "  - [$tag] $msg"
  VER_JSON_ITEMS+=("$(printf '{"status":"%s","message":"%s"}' \
    "$(printf %s "$status" | sed 's/"/\\"/g')" \
    "$(printf %s "$msg" | sed 's/"/\\"/g')")")
}

_check_dns() {
  local host="$1" ip
  if ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}'); then
    _add_result OK "DNS/hosts resolved $host → $ip"
  else
    _add_result WARN "Could not resolve $host (still may work if using IP)"
    return 1
  fi
}

_check_port_445() {
  local host="$1" timeout_s="${2:-3}"
  if have nc; then
    if nc -z -w "$timeout_s" "$host" 445 >/dev/null 2>&1; then
      _add_result OK "TCP/445 reachable on $host"
    else
      _add_result ERR "TCP/445 not reachable on $host (firewall/VPN/route?)"
      return 1
    fi
  elif ((HAS_TIMEOUT)); then
    if timeout "$timeout_s" bash -c ">/dev/tcp/$host/445" 2>/dev/null; then
      _add_result OK "TCP/445 reachable on $host"
    else
      _add_result ERR "TCP/445 not reachable on $host (no nc; used /dev/tcp)"
      return 1
    fi
  else
    _add_result WARN "Cannot test TCP/445 (need nc or timeout)."
  fi
}

_check_smb_probe() {
  local host="$1" credfile="${2:-}"
  if smb_run -gL "//$host" -N >/dev/null 2>&1; then
    _add_result OK "smbclient anonymous listing succeeded on //$host."
    return 0
  fi
  if [[ -n "$credfile" ]] && creds_parse_file "$credfile"; then
    if smb_run -gL "//$host" -m SMB3 -U "${CREDS_USER}%${CREDS_PASS}" >/dev/null 2>&1 ||
      smb_run -gL "//$host" -m SMB2 -U "${CREDS_USER}%${CREDS_PASS}" >/dev/null 2>&1; then
      _add_result OK "smbclient auth listing succeeded on //$host with $credfile"
      return 0
    else
      _add_result ERR "smbclient auth listing failed on //$host using $credfile"
      return 1
    fi
  fi
  _add_result WARN "smbclient probe failed anonymously and no/invalid credfile supplied."
  return 1
}

_check_time_sync() {
  if have timedatectl; then
    local sync
    sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "")
    if [[ "$sync" == "yes" ]]; then
      _add_result OK "Time is NTP-synchronized (timedatectl). SMB auth is time-sensitive."
    else
      _add_result WARN "Time not reported as NTP-synchronized. Kerberos/NTLM may fail if clock skew >5 min."
    fi
  else
    _add_result WARN "timedatectl not available; cannot confirm time sync."
  fi
}

_check_cifs_kernel() {
  if lsmod | grep -q '^cifs'; then
    local v
    v=$(modinfo cifs 2>/dev/null | awk -F': ' '/^version:/{print $2; exit}')
    _add_result OK "cifs kernel module loaded${v:+ (v $v)}"
  else
    if modprobe cifs 2>/dev/null; then
      _add_result WARN "cifs module was not loaded; loaded now."
    else
      _add_result WARN "cifs module not loaded and modprobe failed (may be loaded on host — continuing)."
    fi
  fi
}

_check_fstab_syntax() {
  if findmnt -s >/dev/null 2>&1; then
    _add_result OK "/etc/fstab parses cleanly (findmnt -s)."
  else
    _add_result ERR "findmnt -s reported parse errors for /etc/fstab."
  fi
}

_guess_credfile_for_host() {
  local host="$1"
  awk -v h="//$host/" '
    $0 !~ /^[[:space:]]*#/ && $3=="cifs" && index($1,h)==1 {
      n=split($0,a,",")
      for(i=1;i<=n;i++){
        if(a[i] ~ /credentials=/){ sub(/.*credentials=/,"",a[i]); print a[i]; exit }
      }
    }' /etc/fstab | head -n1
}

_hosts_from_fstab() {
  awk '$0 !~ /^[[:space:]]*#/ && $3=="cifs"{print $1}' /etc/fstab |
    sed -n 's#^//\([^/]\+\)/.*#\1#p' | sort -u
}

do_verify() {
  local host="" credfile=""
  local i=1
  while ((i <= $#)); do
    case "${!i}" in
    --host)
      ((i++))
      host="${!i}"
      ;;
    --cred | --credentials)
      ((i++))
      credfile="${!i}"
      ;;
    *) ;;
    esac
    ((i++))
  done

  if [[ -z "$host" ]]; then
    mapfile -t fhosts < <(_hosts_from_fstab)
    if ((${#fhosts[@]})); then
      if ((HAS_FZF)); then
        host="$(printf "%s\n" "${fhosts[@]}" |
          fzf --prompt="Verify host > " --height=10 --reverse || true)"
      fi
      if [[ -z "$host" ]]; then
        ((FLAG_JSON)) || {
          echo "Select a host from fstab (number) or type a hostname/IP:"
          local idx=1
          for h in "${fhosts[@]}"; do
            printf "  %2d) %s\n" "$idx" "$h"
            ((idx++))
          done
          read -rp "Choice (number or host/IP): " pick
          if [[ "$pick" =~ ^[0-9]+$ ]] && ((pick >= 1 && pick <= ${#fhosts[@]})); then
            host="${fhosts[$((pick - 1))]}"
          else
            host="$pick"
          fi
        }
      fi
    else
      host=$(ASK "Host/IP to verify: ")
    fi
  fi

  host="$(trim "$host")"
  if [[ -z "$host" ]]; then
    _add_result ERR "No host provided for verify."
    jout '{"verify":[]}'
    return 2
  fi

  [[ -z "$credfile" ]] && credfile="$(_guess_credfile_for_host "$host")"
  if [[ -n "$credfile" && ! -f "$credfile" ]]; then
    _add_result WARN "Credfile referenced but not found: $credfile"
    credfile=""
  fi

  ((FLAG_JSON)) || INFO "Verifying SMB host: $host${credfile:+  (cred: $credfile)}"
  VER_JSON_ITEMS=()

  _check_dns "$host"
  _check_port_445 "$host" 3
  _check_smb_probe "$host" "$credfile"
  _check_time_sync
  _check_cifs_kernel
  _check_fstab_syntax

  if ((FLAG_JSON)); then
    local sep="" out='{"verify":['
    for item in "${VER_JSON_ITEMS[@]}"; do
      out+="$sep$item"
      sep=","
    done
    out+=']}'
    printf '%s\n' "$out"
  fi
}

# ===== HEALTH =====
get_opt() {
  local opts="$1" key="$2"
  awk -F',' -v k="$key" \
    '{ for(i=1;i<=NF;i++) if($i~("^"k"=")){ sub("^"k"=","",$i); print $i; exit } }' \
    <<<"$opts"
}
get_idle_timeout() { get_opt "$1" "x-systemd.idle-timeout"; }

_unit_state_for_target() {
  local target="$1"
  if have systemd-escape && have systemctl; then
    local ub
    ub=$(systemd-escape -p "$target")
    local st
    st=$(systemctl is-active "${ub}.mount" 2>/dev/null || echo "unknown")
    if [[ "$st" != "active" ]]; then
      local ast
      ast=$(systemctl is-active "${ub}.automount" 2>/dev/null || echo "")
      [[ -n "$ast" && "$ast" != "unknown" ]] && st="automount:$ast"
    fi
    echo "$st" "$ub"
  else
    echo "unknown" ""
  fi
}

_space_for_target() {
  local target="$1"
  df -hP "$target" 2>/dev/null | awk 'NR==2{printf "used %s / size %s (%s)", $3, $2, $5}'
}

_rw_sanity_test() {
  local target="$1"
  local tf="$target/.smb_manager_health.$$.$RANDOM"
  if (: >"$tf") 2>/dev/null; then
    if printf 'ping\n' >>"$tf" 2>/dev/null; then
      rm -f "$tf" 2>/dev/null
      echo "OK" "write/delete succeeded"
      return 0
    else
      rm -f "$tf" 2>/dev/null
      echo "ERR" "created but failed to write"
      return 1
    fi
  else
    echo "WARN" "no write permission (read-only or ACL)."
    return 2
  fi
}

HEALTH_JSON_ITEMS=()
_emit_mount_health() {
  local target="$1" source="$2" opts="$3" state="$4" unit="$5" \
    space_line="$6" rw_result="$7" rw_msg="$8"
  local vers idle
  vers="$(get_opt "$opts" "vers")"
  idle="$(get_idle_timeout "$opts")"

  if ((!FLAG_JSON)); then
    printf "\nTARGET: %s\nSOURCE: %s\n" "$target" "$source"
    printf "  - state: %s%s\n" "$state" "${unit:+ (unit: $unit)}"
    printf "  - vers: %s\n" "${vers:-unknown}"
    printf "  - idle-timeout: %s\n" "${idle:-none}"
    [[ -n "$space_line" ]] && printf "  - space: %s\n" "$space_line"
    if [[ -n "$rw_result" ]]; then
      if [[ "$rw_result" == OK* ]]; then
        printf "  - rw test: \033[1;32m%s\033[0m %s\n" "$rw_result" "$rw_msg"
      else
        printf "  - rw test: \033[1;31m%s\033[0m %s\n" "$rw_result" "$rw_msg"
      fi
    fi
  fi

  local json_item
  json_item="$(printf \
    '{"target":"%s","source":"%s","state":"%s","unit":"%s","vers":"%s","idle_timeout":"%s","space":"%s","rw":{"status":"%s","message":"%s"}}' \
    "$(json_escape "$target")" "$(json_escape "$source")" \
    "$(json_escape "$state")" "$(json_escape "$unit")" \
    "$(json_escape "${vers:-}")" "$(json_escape "${idle:-}")" \
    "$(json_escape "$space_line")" \
    "$(json_escape "${rw_result:-}")" "$(json_escape "${rw_msg:-}")")"
  HEALTH_JSON_ITEMS+=("$json_item")
}

do_health() {
  local DO_RW=1
  for arg in "$@"; do [[ "$arg" == "--no-rw" ]] && DO_RW=0; done

  mapfile -t lines < <(findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS | awk '$3=="cifs"{print}')
  if ((${#lines[@]} == 0)); then
    hlog "No CIFS mounts detected."
    jout '{"health":[]}'
    return 0
  fi

  HEALTH_JSON_ITEMS=()
  ((FLAG_JSON)) || INFO "Checking health of ${#lines[@]} CIFS mount(s)... (rw test: $( ((DO_RW)) && echo on || echo off))"

  for L in "${lines[@]}"; do
    local target source opts
    target=$(awk '{print $1}' <<<"$L")
    source=$(awk '{print $2}' <<<"$L")
    opts=$(awk '{$1=$2=$3=""; sub(/^   */,""); print}' <<<"$L")

    local mstate="mounted"
    mountpoint -q "$target" 2>/dev/null || mstate="not-mounted"

    local unit_state unit_base
    read -r unit_state unit_base < <(_unit_state_for_target "$target")
    local space_line
    space_line="$(_space_for_target "$target")"

    local rw_status="" rw_msg=""
    if ((DO_RW)); then
      read -r rw_status rw_msg < <(_rw_sanity_test "$target")
    fi

    _emit_mount_health "$target" "$source" "$opts" \
      "$mstate/${unit_state}" "$unit_base" "$space_line" "$rw_status" "$rw_msg"
  done

  if ((FLAG_JSON)); then
    local sep="" out='{"health":['
    for item in "${HEALTH_JSON_ITEMS[@]}"; do
      out+="$sep$item"
      sep=","
    done
    out+=']}'
    printf '%s\n' "$out"
  fi
}

# ===== STATUS =====
_last_error_for_unit() {
  local unit="$1" hours="${2:-24}"
  if have journalctl && [[ -n "$unit" ]]; then
    journalctl -u "${unit}.mount" --since "${hours} hours ago" \
      -p err..alert --no-pager 2>/dev/null |
      tail -n1 | sed 's/^[^:]*: //'
  fi
}

do_status() {
  local SHOW_ALL=0 SHOW_ERRORS=0
  for arg in "$@"; do
    case "$arg" in
    --all) SHOW_ALL=1 ;;
    --errors) SHOW_ERRORS=1 ;;
    esac
  done

  local awk_filter='$3=="cifs"{print}'
  ((SHOW_ALL)) && awk_filter='{print}'

  mapfile -t lines < <(findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS | awk "$awk_filter")
  if ((${#lines[@]} == 0)); then
    hlog "No matching mounts detected."
    jout '{"mounts":[]}'
    return 0
  fi

  if ((!FLAG_JSON)); then
    if ((SHOW_ERRORS)); then
      printf "%-36s %-18s %-18s %-7s %-7s %-4s %-18s %-30s\n" \
        "TARGET" "STATE" "UNIT" "VERS" "IDLE" "MODE" "SPACE" "LAST_ERROR(24h)"
    else
      printf "%-36s %-18s %-18s %-7s %-7s %-4s %-18s\n" \
        "TARGET" "STATE" "UNIT" "VERS" "IDLE" "MODE" "SPACE"
    fi
  fi

  local sep="" out='{"mounts":['
  for L in "${lines[@]}"; do
    local target source fstype opts
    target=$(awk '{print $1}' <<<"$L")
    source=$(awk '{print $2}' <<<"$L")
    fstype=$(awk '{print $3}' <<<"$L")
    opts=$(awk '{$1=$2=$3=""; sub(/^   */,""); print}' <<<"$L")

    local mstate="mounted"
    mountpoint -q "$target" 2>/dev/null || mstate="not-mounted"

    local unit_state unit_base
    read -r unit_state unit_base < <(_unit_state_for_target "$target")

    local vers idle mode space_line last_err=""
    vers="$(get_opt "$opts" "vers")"
    idle="$(get_opt "$opts" "x-systemd.idle-timeout")"
    [[ ",$opts," == *",ro,"* ]] && mode="ro" || mode="rw"
    space_line="$(_space_for_target "$target")"

    if ((SHOW_ERRORS)); then
      last_err="$(_last_error_for_unit "$unit_base" 24)"
      last_err="${last_err:--}"
    fi

    if ((!FLAG_JSON)); then
      if ((SHOW_ERRORS)); then
        printf "%-36s %-18s %-18s %-7s %-7s %-4s %-18s %-30s\n" \
          "$target" "$mstate/${unit_state}" "${unit_base:--}" \
          "${vers:-?}" "${idle:--}" "$mode" "${space_line:--}" "$last_err"
      else
        printf "%-36s %-18s %-18s %-7s %-7s %-4s %-18s\n" \
          "$target" "$mstate/${unit_state}" "${unit_base:--}" \
          "${vers:-?}" "${idle:--}" "$mode" "${space_line:--}"
      fi
    fi

    local last_field=""
    if ((SHOW_ERRORS)); then
      last_field=$(printf ',\"last_error\":\"%s\"' "$(json_escape "${last_err:-}")")
    fi

    local item
    item="$(printf \
      '{"target":"%s","source":"%s","fstype":"%s","state":"%s","unit":"%s","vers":"%s","idle_timeout":"%s","mode":"%s","space":"%s"%s}' \
      "$(json_escape "$target")" "$(json_escape "$source")" \
      "$(json_escape "$fstype")" "$(json_escape "$mstate/$unit_state")" \
      "$(json_escape "${unit_base:-}")" "$(json_escape "${vers:-}")" \
      "$(json_escape "${idle:-}")" "$(json_escape "$mode")" \
      "$(json_escape "${space_line:-}")" "$last_field")"

    out+="${sep}${item}"
    sep=","
  done
  out+=']}'
  jout "$out"
}

# ===== EXPORT / IMPORT (phase 4 — not yet implemented) =====
do_export() {
  INFO "export is not yet implemented."
  INFO "When ready, it will serialize all CIFS fstab entries and credential paths to a portable JSON file."
}
do_import() {
  INFO "import is not yet implemented."
  INFO "When ready, it will restore mounts and credential files from an export JSON."
}

# ===== dispatcher =====
run_command() {
  case "$CMD" in
  create)
    _acquire_write_lock
    do_create "${GLOBAL_ARGS[@]:-}"
    ;;
  unmount)
    _acquire_write_lock
    do_unmount "${GLOBAL_ARGS[@]:-}"
    ;;
  status) do_status "${GLOBAL_ARGS[@]:-}" ;;
  verify) do_verify "${GLOBAL_ARGS[@]:-}" ;;
  health) do_health "${GLOBAL_ARGS[@]:-}" ;;
  export) do_export "${GLOBAL_ARGS[@]:-}" ;;
  import) do_import "${GLOBAL_ARGS[@]:-}" ;;
  help | "") usage ;;
  *)
    ERR "Unknown command: $CMD"
    usage
    exit 2
    ;;
  esac
}

# Environment check runs first — hard exits on WSL1 / unprivileged LXC
check_environment

if [[ -n "$CMD" ]]; then
  run_command
  exit $?
fi

# ===== legacy interactive menu =====
while :; do
  clear >/dev/null 2>&1 || true
  list_cifs_mounts || true
  echo
  echo "Choose an action:"
  echo "  1) Unmount / clean an existing SMB mount"
  echo "  2) Create a new persistent SMB mount"
  echo "  3) Status (enhanced)"
  echo "  4) Verify (self-tests)"
  echo "  5) Health (rw test)"
  echo "  0) Exit"
  echo ""
  echo "  (export / import not yet implemented)"
  case "$(ASK "Select [0-5]: ")" in
  1)
    do_unmount
    read -rp $'\nPress Enter to return to menu... ' _
    ;;
  2)
    do_create
    read -rp $'\nPress Enter to return to menu... ' _
    ;;
  3)
    do_status
    read -rp $'\nPress Enter to return to menu... ' _
    ;;
  4)
    do_verify
    read -rp $'\nPress Enter to return to menu... ' _
    ;;
  5)
    do_health
    read -rp $'\nPress Enter to return to menu... ' _
    ;;
  0)
    INFO "Bye."
    exit 0
    ;;
  *)
    WARN "Unknown choice."
    sleep 1
    ;;
  esac
done