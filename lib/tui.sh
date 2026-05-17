#!/usr/bin/env bash
# =============================================================================
# lib:         tui.sh
# description: TUI adapter. All interactive prompts in raaviutils tools go
#              through these functions. Priority: gum → fzf → select/read.
#              This is the only file in the project that calls gum or fzf.
# sourced-by:  every raaviutils tool via: source <(curl -fsSL .../lib/tui.sh)
# optional:    gum (preferred), fzf (fuzzy picker fallback)
# =============================================================================

_HAS_GUM=0
_HAS_FZF=0
command -v gum >/dev/null 2>&1 && _HAS_GUM=1
command -v fzf >/dev/null 2>&1 && _HAS_FZF=1

# tui_prompt <prompt-text> [default-value]
# Reads a single line of input. Returns the value via stdout.
# Falls back to plain read if gum is absent.
tui_prompt() {
  local prompt_text="$1"
  local default_val="${2:-}"
  local result

  if ((_HAS_GUM)); then
    if [[ -n "$default_val" ]]; then
      result=$(gum input --prompt "${prompt_text}: " --value "$default_val" 2>/dev/null) || true
    else
      result=$(gum input --prompt "${prompt_text}: " 2>/dev/null) || true
    fi
  else
    local prompt_display="${prompt_text}"
    [[ -n "$default_val" ]] && prompt_display="${prompt_text} [${default_val}]"
    read -rp "${prompt_display}: " result
    [[ -z "$result" && -n "$default_val" ]] && result="$default_val"
  fi

  printf '%s' "$result"
}

# tui_password <prompt-text>
# Reads a password (no echo). Returns the value via stdout.
tui_password() {
  local prompt_text="$1"
  local result

  if ((_HAS_GUM)); then
    result=$(gum input --prompt "${prompt_text}: " --password 2>/dev/null) || true
  else
    read -rsp "${prompt_text}: " result
    printf '\n' >&2
  fi

  printf '%s' "$result"
}

# tui_pick <header> <item> [<item> ...]
# Presents a single-select menu. Returns the chosen item via stdout.
# Returns empty string if the user cancels (ESC or empty selection).
tui_pick() {
  local header="$1"
  shift
  local items=("$@")
  local result

  if ((_HAS_GUM)); then
    result=$(printf '%s\n' "${items[@]}" |
      gum choose --header "$header" 2>/dev/null) || true
  elif ((_HAS_FZF)); then
    result=$(printf '%s\n' "${items[@]}" |
      fzf --prompt="${header} > " --height=40% --reverse --no-multi \
        --header="$header" 2>/dev/null) || true
  else
    local i=1
    for item in "${items[@]}"; do
      printf '  %2d) %s\n' "$i" "$item" >&2
      ((i++))
    done
    local choice
    read -rp "Choose [1-${#items[@]}] (0 to cancel): " choice >&2
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#items[@]})); then
      result="${items[$((choice - 1))]}"
    else
      result=""
    fi
  fi

  printf '%s' "$result"
}

# tui_confirm <question>
# Presents a yes/no prompt. Exits 5 (user aborted) if the user says no or cancels.
tui_confirm() {
  local question="$1"

  if ((_HAS_GUM)); then
    if ! gum confirm "$question" 2>/dev/null; then
      exit 5
    fi
  else
    local ans
    read -rp "${question} [y/N]: " ans >&2
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
      exit 5
    fi
  fi
}
