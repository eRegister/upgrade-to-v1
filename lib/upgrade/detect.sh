# shellcheck shell=bash
# =============================================================================
# lib/upgrade/detect.sh — install-vs-upgrade detection & version comparison
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
