#!/usr/bin/env bash
###############################################################################
# eRegister Lesotho — Installer / Upgrader (v0.92 -> v1)
#
# eRegister is an EMR system based on Bahmni. This script works as BOTH a fresh
# installer and an in-place upgrader. Functions are organized into modules under
# lib/ (see DESIGN NOTES); only main() lives here.
#
# USAGE
#   ./install.sh [--yes] [--force] [--install-dir DIR] [--target-ref REF] [--help]
#
# FLAGS / ENV
#   -y, --yes            Non-interactive; assume "yes" to all prompts (CI/automation).
#                        Also enabled with: EREGISTER_ASSUME_YES=1
#   --force              Re-run upgrade even if a completed v1 marker exists.
#   --install-dir DIR    Override install base (default: /var/lib).
#   --target-ref REF     Git ref/tag/commit to check out for the repos (default: main).
#   --no-color           Disable ANSI colors.
#   -h, --help           Show help and exit.
#
# DESIGN NOTES
#   * Modules live under lib/, grouped by concern and sourced by this file:
#       lib/core/    config, logging, traps, prompt, cli
#       lib/system/  platform, privilege, deps
#       lib/upgrade/ verify, detect, backup, migrate, rollback, postinstall
#     Override the lib location with EREGISTER_LIB_DIR (e.g. for system install).
#   * Because functions now live in separate files, this is NO LONGER safe to
#     `curl | bash` directly — clone/download the whole repo and run ./install.sh.
#     (To regain a single pipe-able file, concatenate lib/**/*.sh + main; see
#     the build note at the end of this repo's README.)
#   * ALL logic still lives in functions; main() is called on the LAST line.
###############################################################################

set -euo pipefail

# -----------------------------------------------------------------------------
# Module loader — resolve lib/ relative to this script and source every module.
# Sourcing order follows dependency layering (core -> system -> upgrade); since
# everything but config.sh only *defines* functions, order is otherwise flexible.
# -----------------------------------------------------------------------------
load_modules() {
  local self_dir lib_dir m
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  lib_dir="${EREGISTER_LIB_DIR:-${self_dir}/lib}"

  if [ ! -d "$lib_dir" ]; then
    printf 'FATAL: module dir not found: %s\n' "$lib_dir" >&2
    printf 'Clone the whole repo and run ./install.sh, or set EREGISTER_LIB_DIR.\n' >&2
    exit 1
  fi

  local modules=(
    core/config.sh
    core/logging.sh
    core/traps.sh
    core/prompt.sh
    core/cli.sh
    system/platform.sh
    system/privilege.sh
    system/deps.sh
    upgrade/verify.sh
    upgrade/detect.sh
    upgrade/backup.sh
    upgrade/migrate.sh
    upgrade/rollback.sh
    upgrade/postinstall.sh
  )
  for m in "${modules[@]}"; do
    if [ ! -r "${lib_dir}/${m}" ]; then
      printf 'FATAL: missing module: %s/%s\n' "$lib_dir" "$m" >&2
      exit 1
    fi
    # shellcheck source=/dev/null
    . "${lib_dir}/${m}"
  done
}

# =============================================================================
# main — the single entrypoint (no top-level work happens before this is called)
# =============================================================================
main() {
  load_modules        # bring in all module functions/config before anything else

  parse_args "$@"
  setup_colors
  install_traps
  banner

  # --- discovery (read-only) ---------------------------------------------
  detect_platform
  detect_pkg_mgr
  resolve_config
  detect_privilege
  print_config

  # --- idempotency guard --------------------------------------------------
  if [ -f "$DONE_MARKER" ] && [ "$FORCE" != "1" ]; then
    success "${APP_NAME} ${TARGET_VERSION} already installed (${DONE_MARKER}). Nothing to do."
    success "Re-run with --force to redo the upgrade."
    next_steps
    exit 0
  fi

  # --- overall go/no-go (each step below is also confirmed individually) --
  warn "Cautious mode: you will be asked to confirm EVERY step before it runs."
  warn "Answer 'n' at any prompt to stop safely (with rollback if the old stack"
  warn "has already been frozen). Use --yes to auto-confirm all steps."
  if ! confirm "Begin the upgrade ${CURRENT_VERSION_DEFAULT} -> ${TARGET_VERSION}?"; then
    error "Aborted by user."
    exit 1
  fi

  # --- dependencies -------------------------------------------------------
  confirm_step "Check for, and install if missing, required dependencies (git, docker, …)"
  ensure_deps

  # --- temp workspace + scaffolding --------------------------------------
  confirm_step "Create the temp workspace and the v1 folders under ${INSTALL_BASE}"
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/eregister-v1.XXXXXX")"
  info "Working dir: ${WORKDIR}"
  step "Preparing directories"
  ensure_dir "$V1_DIR" "v1 folder"
  ensure_dir "$BACKUP_DIR" "bahmni-backup folder"

  # --- backup BEFORE touching anything ------------------------------------
  step "Backup"
  confirm_step "Take a MySQL backup of '${DB_NAME}' from container ${EMR_CONTAINER} into ${BACKUP_SQL}"
  prompt_db_password
  take_backup

  # --- stop old stack (rollback armed from here) --------------------------
  step "Migration"
  confirm_step "Freeze (stop, not remove) the running ${CURRENT_VERSION_DEFAULT} stack at ${OLD_DOCKER_DIR}"
  shutdown_old_stack

  # --- bring in v1 sources & 0.92 config ----------------------------------
  confirm_step "Clone the v1 source repos and 0.92 config into ${V1_DIR}"
  fetch_repos

  # --- restore data into v1 ----------------------------------------------
  confirm_step "Run restore_bahmni_standard.sh to load the backup into the v1 stack"
  run_restore

  # --- verify & finish ----------------------------------------------------
  confirm_step "Run post-install verification and finalize the upgrade"
  post_verify
  UPGRADE_COMPLETE="1"   # disarms rollback in the error trap
  next_steps
  success "Done."
}

main "$@"
