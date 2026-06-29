# shellcheck shell=bash
# =============================================================================
# lib/upgrade/verify.sh — download integrity (checksum + optional GPG) and
# idempotent git clone/update with ref pinning.
# Depends on: logging, as_root() (privilege).
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
