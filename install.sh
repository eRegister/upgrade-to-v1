#!/usr/bin/env bash
###############################################################################
# eRegister Lesotho — Installer / Upgrader (v0.92 -> v1)
#
# eRegister is an EMR system based on Bahmni. This single script works as BOTH a
# fresh installer and an in-place upgrader, and is safe to run via:
#
#     curl -fsSL https://<github-url>/install.sh | bash
#
# USAGE
#   curl -fsSL https://<github-url>/install.sh | bash
#   curl -fsSL https://<github-url>/install.sh | bash -s -- --yes
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
#   * "Organized into directories": curl|bash REQUIRES a single self-contained
#     file, so the would-be modules (lib/log, lib/platform, lib/deps,
#     lib/privilege, lib/backup, lib/upgrade, lib/rollback, lib/verify) are kept
#     as clearly delimited sections below. The boundaries mirror a real
#     src/lib/*.sh layout 1:1, so splitting later is mechanical.
#   * ALL logic lives in functions; `main "$@"` is the VERY LAST line so a
#     truncated download can never execute a partial command.
###############################################################################

set -euo pipefail

# =============================================================================
# lib/config.sh — defaults & resolved configuration (overridable via flags/env)
# =============================================================================
APP_NAME="eRegister Lesotho"
CURRENT_VERSION_DEFAULT="0.92"        # assumed version of an existing install
TARGET_VERSION="v1"

INSTALL_BASE="${EREGISTER_INSTALL_BASE:-/var/lib}"   # default install dir
TARGET_REF="${EREGISTER_TARGET_REF:-main}"           # git ref to deploy
ASSUME_YES="${EREGISTER_ASSUME_YES:-0}"
FORCE="0"
USE_COLOR="auto"

# Existing (0.92) deployment layout
OLD_DOCKER_DIR="${EREGISTER_OLD_DOCKER_DIR:-/home/ubuntu/bahmni_docker}"
EMR_CONTAINER="${EREGISTER_EMR_CONTAINER:-bahmni_docker_emr-service_1}"

# OpenMRS DB credentials (used inside the running EMR container for the dump).
# The password is NOT hard-coded: it is prompted interactively at runtime, or
# taken from EREGISTER_DB_PASS for non-interactive/CI use.
DB_NAME="${EREGISTER_DB_NAME:-openmrs}"
DB_USER="${EREGISTER_DB_USER:-root}"
DB_PASS="${EREGISTER_DB_PASS:-}"

# Source repositories
REPO_BAHMNI_DOCKER="https://github.com/Lesotho-eRegister-v1/bahmni-docker-ls"
REPO_STANDARD_CONFIG="https://github.com/Lesotho-eRegister-v1/standard-config-ls"
REPO_CONFIG_092="https://github.com/eRegister/bahmni_config092"

# Derived paths (finalized in resolve_config once INSTALL_BASE is known)
V1_DIR=""             # <base>/v1
BACKUP_DIR=""         # <base>/v1/bahmni-backup
BACKUP_SQL=""         # <base>/v1/bahmni-backup/openmrsdb_backup.sql
DONE_MARKER=""        # <base>/v1/.eregister-upgrade-complete
RESTORE_DIR=""        # <base>/v1/bahmni-docker-ls/bahmni-standard

# Runtime state (for rollback) — touched as the upgrade progresses
WORKDIR=""
OS=""
ARCH=""
PKG_MGR=""
SUDO=""
DOCKER_COMPOSE=""     # "docker compose" or "docker-compose"
OLD_STACK_STOPPED="0"
UPGRADE_COMPLETE="0"

# =============================================================================
# lib/log.sh — colored, leveled logging that degrades on a non-TTY
# =============================================================================
setup_colors() {
  if [ "$USE_COLOR" = "no" ] || { [ "$USE_COLOR" = "auto" ] && [ ! -t 2 ]; }; then
    C_RESET=""; C_INFO=""; C_WARN=""; C_ERR=""; C_OK=""; C_DIM=""; C_HDR=""
  else
    C_RESET=$'\033[0m';  C_INFO=$'\033[34m'; C_WARN=$'\033[33m'
    C_ERR=$'\033[31m';   C_OK=$'\033[32m';   C_DIM=$'\033[2m'; C_HDR=$'\033[36m'
  fi
}
log()     { printf '%s\n' "$*" >&2; }
info()    { printf '%s[ℹ]%s %s\n'  "$C_INFO" "$C_RESET" "$*" >&2; }
warn()    { printf '%s[⚠]%s %s\n'  "$C_WARN" "$C_RESET" "$*" >&2; }
error()   { printf '%s[✘]%s %s\n'  "$C_ERR"  "$C_RESET" "$*" >&2; }
success() { printf '%s[✔]%s %s\n'  "$C_OK"   "$C_RESET" "$*" >&2; }
step()    { printf '\n%s==>%s %s\n' "$C_HDR" "$C_RESET" "$*" >&2; }

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

# =============================================================================
# lib/traps.sh — error reporting, temp-dir cleanup, rollback orchestration
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
  # Always remove the temp working dir; never touch install/backup dirs here.
  [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR" || true
}

install_traps() {
  trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
  trap cleanup EXIT
}

# =============================================================================
# lib/prompt.sh — interactive confirmation that never reads from stdin
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

# =============================================================================
# lib/platform.sh — OS / architecture detection & artifact-name mapping
# =============================================================================
detect_platform() {
  local raw_os raw_arch
  raw_os="$(uname -s)"
  raw_arch="$(uname -m)"

  case "$raw_os" in
    Linux)  OS="linux"  ;;
    Darwin) OS="darwin" ;;
    *) error "Unsupported OS: ${raw_os}. Supported: Linux, macOS."; exit 1 ;;
  esac

  case "$raw_arch" in
    x86_64|amd64)        ARCH="amd64" ;;
    aarch64|arm64)       ARCH="arm64" ;;
    *) error "Unsupported CPU architecture: ${raw_arch}. Supported: amd64, arm64."; exit 1 ;;
  esac

  # The upgrade flow itself is container-based (platform-agnostic), but the
  # full Bahmni stack is only exercised on Linux. Warn loudly on macOS.
  if [ "$OS" = "darwin" ]; then
    warn "macOS detected: the Bahmni Docker stack is supported only on Linux ${ARCH}."
    confirm "Continue anyway?" || { error "Aborted by user."; exit 1; }
  fi
}

# =============================================================================
# lib/privilege.sh — root / sudo handling
# =============================================================================
detect_privilege() {
  # Determine whether we need elevation to write under INSTALL_BASE.
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    return 0
  fi
  if [ -w "$INSTALL_BASE" ] && [ -w "$(dirname "$INSTALL_BASE")" ]; then
    SUDO=""
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
    info "Elevation required for ${INSTALL_BASE}; will use sudo."
    # Prime sudo so later steps don't stall mid-flow.
    if ! sudo -n true 2>/dev/null; then
      confirm "Authorize sudo now?" || { error "Aborted: sudo required."; exit 1; }
      sudo -v </dev/tty || { error "Could not obtain sudo."; exit 1; }
    fi
  else
    error "Root is required to write to ${INSTALL_BASE} but 'sudo' is not available."
    error "Re-run as root, or pass --install-dir to a writable location."
    exit 1
  fi
}

as_root() { if [ -n "$SUDO" ]; then "$SUDO" "$@"; else "$@"; fi; }

# =============================================================================
# lib/deps.sh — package-manager detection & dependency installation
# =============================================================================
detect_pkg_mgr() {
  for m in apt-get dnf yum apk brew; do
    if command -v "$m" >/dev/null 2>&1; then PKG_MGR="$m"; return 0; fi
  done
  PKG_MGR=""
  warn "No supported package manager found (apt/dnf/yum/apk/brew)."
}

pkg_install() {
  # pkg_install <pkg...>
  case "$PKG_MGR" in
    apt-get) as_root apt-get update -y && as_root apt-get install -y "$@" ;;
    dnf)     as_root dnf install -y "$@" ;;
    yum)     as_root yum install -y "$@" ;;
    apk)     as_root apk add --no-cache "$@" ;;
    brew)    brew install "$@" ;;
    *) return 1 ;;
  esac
}

ensure_deps() {
  # Map a command to its package name (usually identical).
  local required=(git curl tar gzip sha256sum docker) missing=()
  local c
  for c in "${required[@]}"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done

  # docker compose plugin / legacy binary
  if command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
      DOCKER_COMPOSE="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
      DOCKER_COMPOSE="docker-compose"
    else
      missing+=("docker-compose-plugin")
    fi
  fi

  if [ "${#missing[@]}" -eq 0 ]; then
    success "All dependencies present."
  else
    warn "Missing dependencies: ${missing[*]}"
    if [ -z "$PKG_MGR" ]; then
      error "Cannot auto-install (no package manager). Install manually: ${missing[*]}"
      exit 1
    fi
    if confirm "Install missing dependencies (${missing[*]}) via ${PKG_MGR}?"; then
      pkg_install "${missing[@]}" || { error "Dependency installation failed."; exit 1; }
    else
      error "Required dependencies missing; cannot continue."
      exit 1
    fi
    # Re-resolve compose after install.
    if docker compose version >/dev/null 2>&1; then DOCKER_COMPOSE="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then DOCKER_COMPOSE="docker-compose"; fi
  fi

  [ -n "$DOCKER_COMPOSE" ] || { error "docker compose not available."; exit 1; }
  docker info >/dev/null 2>&1 || warn "Docker daemon not reachable as current user; some steps may need sudo/root."
}

# =============================================================================
# lib/verify.sh — download integrity (checksum + optional GPG) and git verify
# =============================================================================
verify_checksum() {
  # verify_checksum <file> <expected_sha256>   (fail-closed)
  local file="$1" expected="$2" actual
  [ -n "$expected" ] || { error "No expected checksum provided for ${file}; refusing (fail-closed)."; return 1; }
  actual="$(sha256sum "$file" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    error "Checksum mismatch for ${file}"
    error "  expected: ${expected}"
    error "  actual:   ${actual}"
    return 1
  fi
  success "Checksum OK: $(basename "$file")"
}

verify_gpg() {
  # verify_gpg <file> <sig>   — optional; only enforced if a sig is supplied.
  local file="$1" sig="$2"
  [ -n "$sig" ] || { info "No GPG signature supplied for $(basename "$file"); skipping."; return 0; }
  command -v gpg >/dev/null 2>&1 || { error "gpg required to verify ${sig} but not installed."; return 1; }
  gpg --verify "$sig" "$file" || { error "GPG verification failed for ${file}."; return 1; }
  success "GPG signature OK: $(basename "$file")"
}

git_clone_or_update() {
  # Idempotent clone; verifies the remote and checks out TARGET_REF.
  # git_clone_or_update <repo_url> <dest_dir>
  local url="$1" dest="$2"
  if [ -d "$dest/.git" ]; then
    info "Repo exists, updating: ${dest}"
    as_root git -C "$dest" remote set-url origin "$url"
    as_root git -C "$dest" fetch --depth 1 origin "$TARGET_REF"
    as_root git -C "$dest" checkout -f "$TARGET_REF"
    as_root git -C "$dest" reset --hard "origin/${TARGET_REF}" 2>/dev/null || true
  else
    info "Cloning ${url} -> ${dest}"
    as_root git clone --depth 1 --branch "$TARGET_REF" "$url" "$dest" 2>/dev/null \
      || as_root git clone "$url" "$dest"
  fi
  [ -d "$dest/.git" ] || { error "Clone failed: ${dest}"; return 1; }
  success "Ready: ${dest} @ $(as_root git -C "$dest" rev-parse --short HEAD)"
}

# =============================================================================
# lib/detect.sh — install-vs-upgrade detection & version comparison
# =============================================================================
read_current_version() {
  # Best-effort read of an existing install's version; defaults to 0.92.
  if [ -f "${OLD_DOCKER_DIR}/VERSION" ]; then
    cat "${OLD_DOCKER_DIR}/VERSION"
  elif [ -d "$OLD_DOCKER_DIR" ] || docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$EMR_CONTAINER"; then
    printf '%s' "$CURRENT_VERSION_DEFAULT"
  else
    printf '%s' "none"
  fi
}

# =============================================================================
# lib/backup.sh — OpenMRS MySQL dump from the running EMR container
# =============================================================================
ensure_dir() {
  # ensure_dir <path> <label>  — idempotent, logs "folder created"
  local path="$1" label="$2"
  if [ -d "$path" ]; then
    info "${label} already exists: ${path}"
  else
    as_root mkdir -p "$path"
    success "${label} created: ${path}"
  fi
}

take_backup() {
  log ""
  info "taking backup first…….."
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${EMR_CONTAINER}$"; then
    error "EMR container '${EMR_CONTAINER}' is not running; cannot dump ${DB_NAME}."
    return 1
  fi
  if [ -f "$BACKUP_SQL" ] && [ "$FORCE" != "1" ]; then
    warn "Backup already exists: ${BACKUP_SQL} (use --force to overwrite). Keeping it."
  else
    # MYSQL_PWD keeps the password off the container's process list.
    # Stream the dump out and write it host-side (as root for /var/lib).
    docker exec -e "MYSQL_PWD=${DB_PASS}" "$EMR_CONTAINER" \
      mysqldump --single-transaction --routines --triggers \
                -u "$DB_USER" "$DB_NAME" \
      | as_root tee "$BACKUP_SQL" >/dev/null
    [ -s "$BACKUP_SQL" ] || { error "Backup file is empty: ${BACKUP_SQL}"; return 1; }
  fi
  success "backup created and placed in ${BACKUP_DIR}"
}

# =============================================================================
# lib/rollback.sh — restore the old 0.92 stack if the upgrade fails
# =============================================================================
rollback() {
  warn "Upgrade failed — initiating rollback to ${APP_NAME} ${CURRENT_VERSION_DEFAULT}."
  if [ -f "${OLD_DOCKER_DIR}/docker-compose.yml" ]; then
    info "Bringing the old stack back up (${OLD_DOCKER_DIR})…"
    ( cd "$OLD_DOCKER_DIR" && as_root $DOCKER_COMPOSE up -d ) \
      && success "Old stack restarted." \
      || error "Could not restart old stack automatically — start it manually in ${OLD_DOCKER_DIR}."
  else
    error "Old compose file not found at ${OLD_DOCKER_DIR}; cannot auto-rollback the stack."
  fi
  warn "Your database backup is preserved at: ${BACKUP_SQL}"
  error "Rollback complete. The v1 upgrade was NOT applied."
}

# =============================================================================
# lib/upgrade.sh — the orchestrated migration steps
# =============================================================================
shutdown_old_stack() {
  log ""
  info "Shutting down ${APP_NAME} ${CURRENT_VERSION_DEFAULT}"
  if [ -f "${OLD_DOCKER_DIR}/docker-compose.yml" ]; then
    ( cd "$OLD_DOCKER_DIR" && as_root $DOCKER_COMPOSE down )
    OLD_STACK_STOPPED="1"
    success "Old stack stopped."
  else
    warn "No docker-compose.yml at ${OLD_DOCKER_DIR}; nothing to shut down."
  fi
}

fetch_repos() {
  step "Fetching v1 sources"
  git_clone_or_update "$REPO_BAHMNI_DOCKER"   "${V1_DIR}/bahmni-docker-ls"
  git_clone_or_update "$REPO_STANDARD_CONFIG" "${V1_DIR}/standard-config-ls"
  # 0.92 config goes alongside the backup and is renamed to bahmni_config.
  git_clone_or_update "$REPO_CONFIG_092"      "${BACKUP_DIR}/bahmni_config"
}

run_restore() {
  step "Restoring data into v1"
  local restore_script="${RESTORE_DIR}/restore_bahmni_standard.sh"
  [ -d "$RESTORE_DIR" ] || { error "Missing ${RESTORE_DIR}."; return 1; }
  [ -f "$restore_script" ] || { error "Restore script not found: ${restore_script}"; return 1; }
  as_root chmod +x "$restore_script" || true
  info "Running restore (this can take a while)…"
  ( cd "$RESTORE_DIR" && as_root ./restore_bahmni_standard.sh "$BACKUP_DIR" )
  success "Restore completed."
}

# =============================================================================
# lib/postinstall.sh — verification & "what to do next"
# =============================================================================
post_verify() {
  step "Post-install verification"
  local ok=1
  [ -s "$BACKUP_SQL" ]                        || { error "Missing DB backup."; ok=0; }
  [ -d "${V1_DIR}/bahmni-docker-ls/.git" ]    || { error "bahmni-docker-ls missing."; ok=0; }
  [ -d "${V1_DIR}/standard-config-ls/.git" ]  || { error "standard-config-ls missing."; ok=0; }
  [ -d "${BACKUP_DIR}/bahmni_config/.git" ]   || { error "bahmni_config missing."; ok=0; }
  [ "$ok" = "1" ] || return 1
  as_root touch "$DONE_MARKER"
  success "Verification passed."
}

next_steps() {
  cat >&2 <<EOF

${C_OK}══════════════════════════════════════════════════════════════${C_RESET}
${C_OK} ✔ ${APP_NAME} upgraded to ${TARGET_VERSION}${C_RESET}
${C_OK}══════════════════════════════════════════════════════════════${C_RESET}

  Install dir : ${V1_DIR}
  DB backup   : ${BACKUP_SQL}
  v1 stack    : ${V1_DIR}/bahmni-docker-ls

  What to do next:
    1. cd ${V1_DIR}/bahmni-docker-ls/bahmni-standard
    2. Review .env / config, then start the stack:
         ${DOCKER_COMPOSE} up -d
    3. Confirm services are healthy:
         ${DOCKER_COMPOSE} ps
    4. Once verified, the old install in ${OLD_DOCKER_DIR} can be archived.

  Re-running this script is safe (idempotent). Use --force to redo a
  completed upgrade.
EOF
}

# =============================================================================
# lib/cli.sh — argument parsing, config resolution, summary
# =============================================================================
usage() { sed -n '2,40p' "$0" 2>/dev/null || true; }

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -y|--yes)       ASSUME_YES="1" ;;
      --force)        FORCE="1" ;;
      --install-dir)  INSTALL_BASE="${2:?--install-dir needs a value}"; shift ;;
      --target-ref)   TARGET_REF="${2:?--target-ref needs a value}"; shift ;;
      --no-color)     USE_COLOR="no" ;;
      -h|--help)      usage; exit 0 ;;
      *) error "Unknown argument: $1"; usage; exit 2 ;;
    esac
    shift
  done
}

resolve_config() {
  V1_DIR="${INSTALL_BASE}/v1"
  BACKUP_DIR="${V1_DIR}/bahmni-backup"
  BACKUP_SQL="${BACKUP_DIR}/openmrsdb_backup.sql"
  DONE_MARKER="${V1_DIR}/.eregister-upgrade-complete"
  RESTORE_DIR="${V1_DIR}/bahmni-docker-ls/bahmni-standard"
}

print_config() {
  local current; current="$(read_current_version)"
  step "Resolved configuration"
  cat >&2 <<EOF
  ${C_DIM}App${C_RESET}            : ${APP_NAME}
  ${C_DIM}Current ver${C_RESET}    : ${current}
  ${C_DIM}Target ver${C_RESET}     : ${TARGET_VERSION}  (ref: ${TARGET_REF})
  ${C_DIM}OS / Arch${C_RESET}      : ${OS} / ${ARCH}
  ${C_DIM}Pkg manager${C_RESET}    : ${PKG_MGR:-none}
  ${C_DIM}Install base${C_RESET}   : ${INSTALL_BASE}
  ${C_DIM}v1 dir${C_RESET}         : ${V1_DIR}
  ${C_DIM}Old stack${C_RESET}      : ${OLD_DOCKER_DIR}
  ${C_DIM}EMR container${C_RESET}  : ${EMR_CONTAINER}
  ${C_DIM}Privilege${C_RESET}      : $( [ -n "$SUDO" ] && echo "sudo" || echo "direct" )
  ${C_DIM}Non-interactive${C_RESET}: $( [ "$ASSUME_YES" = "1" ] && echo "yes" || echo "no" )
EOF
}

# =============================================================================
# main — the single entrypoint (no top-level work happens before this is called)
# =============================================================================
main() {
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

  # --- confirm destructive migration -------------------------------------
  if ! confirm "Proceed with upgrade ${CURRENT_VERSION_DEFAULT} -> ${TARGET_VERSION} (stops the running stack)?"; then
    error "Aborted by user."
    exit 1
  fi

  # --- dependencies -------------------------------------------------------
  ensure_deps

  # --- temp workspace -----------------------------------------------------
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/eregister-v1.XXXXXX")"
  info "Working dir: ${WORKDIR}"

  # --- scaffolding --------------------------------------------------------
  step "Preparing directories"
  ensure_dir "$V1_DIR" "v1 folder"
  ensure_dir "$BACKUP_DIR" "bahmni-backup folder"

  # --- backup BEFORE touching anything ------------------------------------
  step "Backup"
  prompt_db_password
  take_backup

  # --- stop old stack (rollback armed from here) --------------------------
  step "Migration"
  shutdown_old_stack

  # --- bring in v1 sources & 0.92 config ----------------------------------
  fetch_repos

  # --- restore data into v1 ----------------------------------------------
  run_restore

  # --- verify & finish ----------------------------------------------------
  post_verify
  UPGRADE_COMPLETE="1"   # disarms rollback in the error trap
  next_steps
  success "Done."
}

main "$@"
