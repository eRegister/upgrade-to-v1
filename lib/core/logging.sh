# shellcheck shell=bash
# =============================================================================
# lib/core/logging.sh — colored, leveled logging that degrades on a non-TTY
# =============================================================================
setup_colors() {
  if [ "$USE_COLOR" = "no" ] || { [ "$USE_COLOR" = "auto" ] && [ ! -t 2 ]; }; then
    C_RESET=""; C_INFO=""; C_WARN=""; C_ERR=""; C_OK=""; C_DIM=""; C_HDR=""; C_BOLD=""
  else
    C_RESET=$'\033[0m';  C_INFO=$'\033[34m'; C_WARN=$'\033[33m'
    C_ERR=$'\033[31m';   C_OK=$'\033[32m';   C_DIM=$'\033[2m'; C_HDR=$'\033[36m'
    C_BOLD=$'\033[1m'
  fi
}
log()     { printf '%s\n' "$*" >&2; }
info()    { printf '%s[ℹ]%s %s\n'  "$C_INFO" "$C_RESET" "$*" >&2; }
warn()    { printf '%s[⚠]%s %s\n'  "$C_WARN" "$C_RESET" "$*" >&2; }
error()   { printf '%s[✘]%s %s\n'  "$C_ERR"  "$C_RESET" "$*" >&2; }
success() { printf '%s[✔]%s %s\n'  "$C_OK"   "$C_RESET" "$*" >&2; }
step()    { printf '\n%s==>%s %s\n' "$C_HDR" "$C_RESET" "$*" >&2; }
# Like warn, but the whole message is bold yellow and padded with blank lines —
# for notices that must not be lost in the surrounding output.
notice()  { printf '\n%s%s[⚠] %s%s\n\n' "$C_BOLD" "$C_WARN" "$*" "$C_RESET" >&2; }

banner() {
  # Clean unicode, installer-style splash.
  printf '%s' "$C_HDR" >&2
  cat >&2 <<'EOF'

  ┌────────────────────────────────────────────────────────────┐
  │                                                            │
  │     ███  eRegister Lesotho — Upgrade to v1                 │
  │                                                            │
  │     ⏳  Initializing migration…………                         │
  │     🔍  Checking prerequisites…….                          │
  │     ✨  Doing the magic………                                 │
  │                                                            │
  └────────────────────────────────────────────────────────────┘
EOF
  printf '%s\n' "$C_RESET" >&2
}
