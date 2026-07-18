# shellcheck shell=bash
# =============================================================================
# lib/upgrade/postinstall.sh — post-install verification & "what to do next"
# Depends on: logging, as_root() (privilege).
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
  persist_env
  success "Verification passed."
}

persist_env() {
  # Persist eRegister_HOME beyond this process so future shell sessions (and
  # scripts run from them) can find the v1 tree. profile.d only reaches login
  # shells — daemons/cron jobs still need the path passed explicitly.
  local profile="/etc/profile.d/eregister.sh"
  if [ ! -d /etc/profile.d ]; then
    warn "No /etc/profile.d on this system; eRegister_HOME not persisted."
    return 0
  fi
  printf '# Written by the eRegister v1 installer — re-running it overwrites this file.\nexport eRegister_HOME=%q\n' "$eRegister_HOME" \
    | as_root tee "$profile" >/dev/null
  as_root chmod 0644 "$profile"
  success "eRegister_HOME persisted to ${profile} (takes effect in new login shells)."
}

next_steps() {
  local backup_size dc
  # '|| true' so a missing/unreadable backup never aborts next_steps under set -e.
  backup_size="$(as_root du -h "$BACKUP_SQL" 2>/dev/null | awk '{print $1}' || true)"
  [ -n "$backup_size" ] && backup_size=" (${backup_size})"
  # DOCKER_COMPOSE is only resolved in ensure_deps, which the "already installed"
  # early-exit path skips — fall back to a sensible default so the printed
  # commands are never blank.
  dc="${DOCKER_COMPOSE:-docker compose}"
  cat >&2 <<EOF

${C_OK}══════════════════════════════════════════════════════════════${C_RESET}
${C_OK} ✔ ${APP_NAME} upgraded to ${TARGET_VERSION}${C_RESET}
${C_OK}══════════════════════════════════════════════════════════════${C_RESET}

  Install dir : ${V1_DIR}
  DB backup   : ${BACKUP_SQL}${backup_size}
  v1 stack    : ${V1_DIR}/bahmni-docker-ls
  Environment : eRegister_HOME=${eRegister_HOME} (persisted in /etc/profile.d/eregister.sh)

  The v1 stack has been started (run-bahmni.sh, or '${dc} up -d').

  What to do next:
    1. cd ${V1_DIR}/bahmni-docker-ls/bahmni-standard
    2. Confirm services are healthy:
         ${dc} ps
    3. If anything is down, bring it up with:
         ${dc} up -d
    4. After the instance is FULLY up and the OCL import has finished
       (~30+ min), apply the OCL concept-name fix (run once):
         curl -fsSL ${RAW_BASE}/ocl-fix.sh | bash
       (or, from the upgrade repo:  ./ocl-fix.sh)
    5. Once verified, the old install in ${OLD_DOCKER_DIR} can be archived.

  Re-running this script is safe (idempotent). Use --force to redo a
  completed upgrade.

${C_ERR}  ⚠ Please wait ~30+ minutes before using eRegister. The v1 services
    need time to fully start up, and this can take considerably longer
    depending on the server hardware hosting eRegister.${C_RESET}
EOF
}
