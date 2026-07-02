# shellcheck shell=bash
# =============================================================================
# lib/core/config.sh — defaults & resolved configuration
# Overridable via flags (see lib/core/cli.sh) or environment variables.
# Sourced by install.sh; sets module-global variables at source time.
# =============================================================================
APP_NAME="eRegister Lesotho"
CURRENT_VERSION_DEFAULT="0.92"        # assumed version of an existing install
TARGET_VERSION="v1"

INSTALL_BASE="${EREGISTER_INSTALL_BASE:-/var/lib}"   # default install dir
# Global ref override: when non-empty, forces this git ref for ALL repos.
# Empty = use the per-repo defaults below (repos don't share a branch name).
TARGET_REF="${EREGISTER_TARGET_REF:-}"
ASSUME_YES="${EREGISTER_ASSUME_YES:-0}"
FORCE="0"
USE_COLOR="auto"

# Existing (0.92) deployment layout
OLD_DOCKER_DIR="${EREGISTER_OLD_DOCKER_DIR:-${HOME}/bahmni_docker}"
EMR_CONTAINER="${EREGISTER_EMR_CONTAINER:-bahmni_docker-emr-service-1}"

# OpenMRS DB credentials (used inside the running EMR container for the dump).
# The password is NOT hard-coded: it is prompted interactively at runtime, or
# taken from EREGISTER_DB_PASS for non-interactive/CI use.
DB_NAME="${EREGISTER_DB_NAME:-openmrs}"
DB_USER="${EREGISTER_DB_USER:-root}"
DB_PASS="${EREGISTER_DB_PASS:-}"

# v1 (target) stack — compose service names + the OCL config dir *inside* the
# EMR service. Used by the post-startup OCL concept-name fix (ocl-fix.sh).
# The v1 DB password is normally the container's own MYSQL_ROOT_PASSWORD; set
# EREGISTER_DB_PASS only if it differs.
DB_SERVICE="${EREGISTER_DB_SERVICE:-openmrsdb}"
EMR_SERVICE="${EREGISTER_EMR_SERVICE:-openmrs}"
OCL_DIR="${EREGISTER_OCL_DIR:-/openmrs/data/configuration/ocl}"

# Raw base for self-bootstrapping the standalone helpers (kept in sync with the
# same default in install.sh / ocl-fix.sh).
RAW_BASE="${EREGISTER_RAW_BASE:-https://raw.githubusercontent.com/eRegister/upgrade-to-v1/refs/heads/main}"

# Source repositories
REPO_BAHMNI_DOCKER="https://github.com/Lesotho-eRegister-v1/bahmni-docker-ls"
REPO_STANDARD_CONFIG="https://github.com/Lesotho-eRegister-v1/standard-config-ls"
REPO_CONFIG_092="https://github.com/eRegister/bahmni_config092"

# Per-repo git refs (branch/tag/sha). The Lesotho repos have no 'main' branch;
# their v1 line lives on 'Bokang-changes'. config092 uses 'main'.
# A non-empty TARGET_REF (global override) supersedes all of these.
REF_BAHMNI_DOCKER="${EREGISTER_REF_BAHMNI_DOCKER:-Bokang-changes}"
REF_STANDARD_CONFIG="${EREGISTER_REF_STANDARD_CONFIG:-Bokang-changes}"
REF_CONFIG_092="${EREGISTER_REF_CONFIG_092:-main}"

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
