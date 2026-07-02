# shellcheck shell=bash
# =============================================================================
# lib/upgrade/migrate.sh — the orchestrated migration steps: freeze old stack,
# fetch v1 sources, run the restore.
# Depends on: logging, as_root() (privilege), git_clone_or_update() (verify).
# =============================================================================
shutdown_old_stack() {
  log ""
  info "Shutting down ${APP_NAME} ${CURRENT_VERSION_DEFAULT}"
  if [ -f "${OLD_DOCKER_DIR}/docker-compose.yml" ]; then
    # 'stop' (not 'down') freezes the containers in place — they are halted but
    # NOT removed, so volumes/networks stay intact and rollback is a fast
    # 'start' with no re-create. Then continue straight on with the upgrade.
    ( cd "$OLD_DOCKER_DIR" && as_root $DOCKER_COMPOSE stop )
    OLD_STACK_STOPPED="1"
    success "Old stack stopped (containers frozen, not removed)."
  else
    warn "No docker-compose.yml at ${OLD_DOCKER_DIR}; nothing to shut down."
  fi
}

fetch_repos() {
  step "Fetching v1 sources"
  git_clone_or_update "$REPO_BAHMNI_DOCKER"   "${V1_DIR}/bahmni-docker-ls"    "$REF_BAHMNI_DOCKER"
  git_clone_or_update "$REPO_STANDARD_CONFIG" "${V1_DIR}/standard-config-ls"  "$REF_STANDARD_CONFIG"
  # 0.92 config goes alongside the backup and is renamed to bahmni_config.
  git_clone_or_update "$REPO_CONFIG_092"      "${BACKUP_DIR}/bahmni_config"   "$REF_CONFIG_092"
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

start_v1_stack() {
  # Bring up eRegister v1: prefer run-bahmni.sh; if it errors (or is missing),
  # fall back to a plain 'docker compose up -d'. The run-bahmni.sh call is in an
  # 'if' so a non-zero exit triggers the fallback instead of the ERR trap.
  step "Starting eRegister ${TARGET_VERSION}"
  local run_script="${RESTORE_DIR}/run-bahmni.sh"
  if [ -f "$run_script" ]; then
    as_root chmod +x "$run_script" || true
    info "Launching via run-bahmni.sh…"
    if ( cd "$RESTORE_DIR" && as_root ./run-bahmni.sh ); then
      success "eRegister ${TARGET_VERSION} started via run-bahmni.sh."
      return 0
    fi
    warn "run-bahmni.sh returned an error — falling back to '${DOCKER_COMPOSE} up -d'."
  else
    warn "run-bahmni.sh not found in ${RESTORE_DIR}; using '${DOCKER_COMPOSE} up -d'."
  fi
  ( cd "$RESTORE_DIR" && as_root $DOCKER_COMPOSE up -d )
  success "eRegister ${TARGET_VERSION} started via docker compose."
}
