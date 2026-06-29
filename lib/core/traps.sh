# shellcheck shell=bash
# =============================================================================
# lib/core/traps.sh — error reporting, temp-dir cleanup, rollback orchestration
# Depends on: error() (logging), rollback() (lib/upgrade/rollback.sh).
# =============================================================================
on_error() {
  local line="$1" cmd="$2"
  error "Failed at line ${line}: ${cmd}"
  # If we already stopped the old stack but never finished, attempt rollback.
  if [ "$OLD_STACK_STOPPED" = "1" ] && [ "$UPGRADE_COMPLETE" != "1" ]; then
    rollback
  fi
}

cleanup() {
  # Always remove the temp working dir and any downloaded-modules temp dir;
  # never touch install/backup dirs here.
  [ -n "${WORKDIR:-}" ]       && [ -d "$WORKDIR" ]       && rm -rf "$WORKDIR"       || true
  [ -n "${BOOTSTRAP_DIR:-}" ] && [ -d "$BOOTSTRAP_DIR" ] && rm -rf "$BOOTSTRAP_DIR" || true
}

install_traps() {
  trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
  trap cleanup EXIT
}
