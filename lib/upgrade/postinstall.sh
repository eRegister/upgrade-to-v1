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

  The v1 stack has been started (run-bahmni.sh, or '${DOCKER_COMPOSE} up -d').

  What to do next:
    1. cd ${V1_DIR}/bahmni-docker-ls/bahmni-standard
    2. Confirm services are healthy:
         ${DOCKER_COMPOSE} ps
    3. If anything is down, bring it up with:
         ${DOCKER_COMPOSE} up -d
    4. Once verified, the old install in ${OLD_DOCKER_DIR} can be archived.

  Re-running this script is safe (idempotent). Use --force to redo a
  completed upgrade.
EOF
}
