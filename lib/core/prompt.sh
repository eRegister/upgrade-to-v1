# shellcheck shell=bash
# =============================================================================
# lib/core/prompt.sh — interactive confirmation that never reads from stdin
# (stdin is the script itself when piped into bash; we always use /dev/tty).
# Depends on: logging, rollback() (lib/upgrade/rollback.sh) for confirm_step.
# =============================================================================
confirm() {
  # confirm "Question?"  -> returns 0 for yes, 1 for no
  local prompt="$1" reply=""
  if [ "$ASSUME_YES" = "1" ]; then
    info "${prompt} -> yes (non-interactive)"
    return 0
  fi
  if [ ! -r /dev/tty ]; then
    error "No TTY available for prompt: '${prompt}'. Re-run with --yes for non-interactive mode."
    return 1
  fi
  printf '%s%s [y/N]: %s' "$C_WARN" "$prompt" "$C_RESET" >/dev/tty
  read -r reply </dev/tty || reply=""
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

confirm_step() {
  # Gate a single migration step. Declining aborts cleanly — and if the old
  # stack was already frozen, it rolls back first so you are never left in a
  # half-upgraded state. Honors --yes / EREGISTER_ASSUME_YES (auto-confirms).
  local what="$1"
  if confirm "Next step: ${what} — proceed?"; then
    return 0
  fi
  warn "Step declined by user: ${what}"
  if [ "$OLD_STACK_STOPPED" = "1" ] && [ "$UPGRADE_COMPLETE" != "1" ]; then
    rollback
  fi
  error "Upgrade aborted by user before completion. No further changes made."
  exit 1
}

prompt_db_password() {
  # Obtain the OpenMRS DB password without ever reading from the script's stdin.
  # Priority: 1) EREGISTER_DB_PASS env var, 2) silent prompt from /dev/tty.
  if [ -n "${DB_PASS:-}" ]; then
    info "Using OpenMRS DB password from environment (EREGISTER_DB_PASS)."
    return 0
  fi
  if [ "$ASSUME_YES" = "1" ]; then
    error "Non-interactive mode but no DB password set. Provide it via EREGISTER_DB_PASS."
    exit 1
  fi
  if [ ! -r /dev/tty ]; then
    error "No TTY available to prompt for the DB password. Set EREGISTER_DB_PASS instead."
    exit 1
  fi
  local p1 p2
  while :; do
    printf '%sEnter OpenMRS (%s) password for user '\''%s'\'': %s' \
      "$C_WARN" "$DB_NAME" "$DB_USER" "$C_RESET" >/dev/tty
    IFS= read -rs p1 </dev/tty; printf '\n' >/dev/tty   # -s: no echo
    if [ -z "$p1" ]; then warn "Password cannot be empty."; continue; fi
    printf '%sConfirm password: %s' "$C_WARN" "$C_RESET" >/dev/tty
    IFS= read -rs p2 </dev/tty; printf '\n' >/dev/tty
    if [ "$p1" != "$p2" ]; then warn "Passwords do not match — try again."; continue; fi
    DB_PASS="$p1"; break
  done
  success "Password captured."
}
