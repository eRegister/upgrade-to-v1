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

# True when the old EMR container is up and can be dumped. Callers use this to
# decide whether the backup step runs at all (a fresh install has no container).
emr_container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${EMR_CONTAINER}$"
}

take_backup() {
  log ""
  info "taking backup first…….."
  # No running EMR container = nothing to back up (fresh install). Don't abort:
  # flag it and let the run continue; restore/verify adapt via BACKUP_SKIPPED.
  if ! emr_container_running; then
    warn "EMR container '${EMR_CONTAINER}' is not running — skipping backup (fresh install, nothing to migrate)."
    BACKUP_SKIPPED="1"
    return 0
  fi
  if [ -f "$BACKUP_SQL" ] && [ "$FORCE" != "1" ]; then
    warn "Backup already exists: ${BACKUP_SQL} (use --force to overwrite). Keeping it."
  else
    # MYSQL_PWD keeps the password off the container's process list.
    # Dump EVERYTHING in the openmrs db so the restore is self-contained:
    #   --single-transaction  consistent InnoDB snapshot without locking writers
    #   --routines            stored procedures & functions
    #   --triggers            table triggers
    #   --events              scheduled events
    #   --databases           emit CREATE DATABASE / USE so the db is recreated
    #   --hex-blob            binary-safe encoding of BLOB/BINARY columns
    #   --default-character-set=utf8mb4  no truncation/corruption of unicode text
    # Stream the dump out and write it host-side (as root for /var/lib).
    docker exec -e "MYSQL_PWD=${DB_PASS}" "$EMR_CONTAINER" \
      mysqldump --single-transaction --routines --triggers --events \
                --hex-blob --default-character-set=utf8mb4 \
                --databases -u "$DB_USER" "$DB_NAME" \
      | as_root tee "$BACKUP_SQL" >/dev/null
    [ -s "$BACKUP_SQL" ] || { error "Backup file is empty: ${BACKUP_SQL}"; return 1; }
  fi
  success "backup created and placed in ${BACKUP_DIR}"
}
