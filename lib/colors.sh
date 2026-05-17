#!/usr/bin/env bash
# =============================================================================
# lib:         colors.sh
# description: ANSI color variables and message helpers. TTY-gated: colors are
#              suppressed when stderr is not a terminal (piped output).
#              All user-facing messages go to stderr.
# sourced-by:  every raaviutils tool via: source <(curl -fsSL .../lib/colors.sh)
# =============================================================================

# Colors — empty strings when stderr is not a terminal
if [ -t 2 ]; then
  C_RED='\033[1;31m'
  C_GRN='\033[1;32m'
  C_YLW='\033[1;33m'
  C_BLU='\033[1;34m'
  C_CYN='\033[1;36m'
  C_NC='\033[0m'
else
  C_RED=''
  C_GRN=''
  C_YLW=''
  C_BLU=''
  C_CYN=''
  C_NC=''
fi

# Message helpers — all write to stderr
msg_ok()    { printf "${C_GRN}[OK]${C_NC}    %s\n" "$*" >&2; }
msg_info()  { printf "${C_BLU}[INFO]${C_NC}  %s\n" "$*" >&2; }
msg_warn()  { printf "${C_YLW}[WARN]${C_NC}  %s\n" "$*" >&2; }
msg_err()   { printf "${C_RED}[ERROR]${C_NC} %s\n" "$*" >&2; }
msg_fatal() { printf "${C_RED}[FATAL]${C_NC} %s\n" "$*" >&2; exit 1; }
