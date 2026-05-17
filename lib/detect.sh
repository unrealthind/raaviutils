#!/usr/bin/env bash
# =============================================================================
# lib:         detect.sh
# description: Binary presence checks, distro detection, package manager
#              detection. Sourced by tools that need environment awareness.
# sourced-by:  every raaviutils tool via: source <(curl -fsSL .../lib/detect.sh)
# requires:    colors.sh sourced before this file
# =============================================================================

# have <cmd> — silent binary check, returns 0/1
have() { command -v "$1" >/dev/null 2>&1; }

# need <cmd> [install-hint] — exits 3 with an error if cmd is missing
need() {
  local cmd="$1"
  local hint="${2:-}"
  if ! have "$cmd"; then
    if [[ -n "$hint" ]]; then
      msg_err "Required command not found: ${cmd}. Install with: ${hint}"
    else
      msg_err "Required command not found: ${cmd}. Install it and re-run."
    fi
    exit 3
  fi
}

# distro — prints one of: arch | debian | fedora | unknown
distro() {
  if [[ -f /etc/arch-release ]]; then
    echo "arch"
  elif [[ -f /etc/debian_version ]]; then
    echo "debian"
  elif [[ -f /etc/fedora-release ]]; then
    echo "fedora"
  else
    echo "unknown"
  fi
}

# pkg_manager — prints one of: pacman | apt | dnf | unknown
pkg_manager() {
  if have pacman; then
    echo "pacman"
  elif have apt-get; then
    echo "apt"
  elif have dnf; then
    echo "dnf"
  else
    echo "unknown"
  fi
}
