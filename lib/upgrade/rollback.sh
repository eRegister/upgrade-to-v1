# shellcheck shell=bash
# =============================================================================
# lib/upgrade/rollback.sh — un-freeze the old 0.92 stack if the upgrade fails
# or is aborted after the freeze. Called from traps.sh and prompt.sh.
# Depends on: logging, as_root() (privilege).
# =============================================================================
rollback() {
  warn "Upgrade failed — initiating rollback to ${APP_NAME} ${CURRENT_VERSION_DEFAULT}."
  if [ -f "${OLD_DOCKER_DIR}/docker-compose.yml" ]; then
    info "Restarting the frozen old stack (${OLD_DOCKER_DIR})…"
    # Containers were only 'stop'ped, so 'start' brings them back as-is.
    ( cd "$OLD_DOCKER_DIR" && as_root $DOCKER_COMPOSE start ) \
      && success "Old stack restarted." \
      || error "Could not restart old stack automatically — run '$DOCKER_COMPOSE start' in ${OLD_DOCKER_DIR}."
  else
    error "Old compose file not found at ${OLD_DOCKER_DIR}; cannot auto-rollback the stack."
  fi
  warn "Your database backup is preserved at: ${BACKUP_SQL}"
  error "Rollback complete. The v1 upgrade was NOT applied."
}
