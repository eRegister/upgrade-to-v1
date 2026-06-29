# shellcheck shell=bash
# =============================================================================
# lib/upgrade/backup.sh — directory scaffolding + OpenMRS MySQL dump from the
# running EMR container, taken BEFORE anything is changed.
# Depends on: logging, as_root() (privilege).
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
