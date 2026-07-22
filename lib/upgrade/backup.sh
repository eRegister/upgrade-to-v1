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

# True when a container with EXACTLY the given name is running.
container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${1}$"
}

# Resolve which container hosts the EMR service and set EMR_CONTAINER to it.
# Tries the configured name, then the known alternate (EMR_CONTAINER_ALT). If
# neither is up, asks the user for the running service's name — unless we're
# non-interactive, in which case we can't ask and simply report failure.
# Returns 0 with EMR_CONTAINER pointing at a RUNNING container, or 1 when none
# is available / the user entered nothing (caller then skips the backup).
resolve_emr_container() {
  local name
  for name in "$EMR_CONTAINER" "$EMR_CONTAINER_ALT"; do
    if [ -n "$name" ] && container_running "$name"; then
      EMR_CONTAINER="$name"
      info "Found running EMR container: ${EMR_CONTAINER}"
      return 0
    fi
  done

  warn "None of the known EMR docker services are running:"
  warn "  • ${EMR_CONTAINER}"
  warn "  • ${EMR_CONTAINER_ALT}"

  # Can't prompt without a TTY (or when auto-confirming); skip rather than hang.
  if [ "$ASSUME_YES" = "1" ] || [ ! -r /dev/tty ]; then
    warn "Non-interactive (or no TTY): cannot ask for a container name — skipping backup."
    return 1
  fi

  local entered=""
  printf '%sEnter the name of the running docker service hosting the EMR (leave blank to skip): %s' \
    "$C_WARN" "$C_RESET" >/dev/tty
  read -r entered </dev/tty || entered=""
  if [ -z "$entered" ]; then
    warn "Nothing entered — proceeding to the next step without a backup."
    return 1
  fi
  if ! container_running "$entered"; then
    warn "Container '${entered}' is not running — proceeding to the next step without a backup."
    return 1
  fi
  EMR_CONTAINER="$entered"
  success "Using EMR container: ${EMR_CONTAINER}"
  return 0
}

take_backup() {
  log ""
  info "taking backup first…….."
  # Defensive: resolve_emr_container should have set EMR_CONTAINER to a running
  # container before we get here. If it somehow isn't (e.g. stopped in between),
  # don't abort — flag it and let the run continue as a fresh install.
  if ! container_running "$EMR_CONTAINER"; then
    warn "EMR container '${EMR_CONTAINER}' is not running — skipping backup (nothing to migrate)."
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
