# shellcheck shell=bash
# =============================================================================
# lib/system/deps.sh — package-manager detection & dependency installation
# Depends on: logging, confirm() (prompt), as_root() (privilege).
# =============================================================================
detect_pkg_mgr() {
  for m in apt-get dnf yum apk brew; do
    if command -v "$m" >/dev/null 2>&1; then PKG_MGR="$m"; return 0; fi
  done
  PKG_MGR=""
  warn "No supported package manager found (apt/dnf/yum/apk/brew)."
}

pkg_install() {
  # pkg_install <pkg...>
  case "$PKG_MGR" in
    apt-get) as_root apt-get update -y && as_root apt-get install -y "$@" ;;
    dnf)     as_root dnf install -y "$@" ;;
    yum)     as_root yum install -y "$@" ;;
    apk)     as_root apk add --no-cache "$@" ;;
    brew)    brew install "$@" ;;
    *) return 1 ;;
  esac
}

ensure_deps() {
  # Map a command to its package name (usually identical).
  local required=(git curl tar gzip sha256sum docker) missing=()
  local c
  for c in "${required[@]}"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done

  # docker compose plugin / legacy binary
  if command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
      DOCKER_COMPOSE="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
      DOCKER_COMPOSE="docker-compose"
    else
      missing+=("docker-compose-plugin")
    fi
  fi

  if [ "${#missing[@]}" -eq 0 ]; then
    success "All dependencies present."
  else
    warn "Missing dependencies: ${missing[*]}"
    if [ -z "$PKG_MGR" ]; then
      error "Cannot auto-install (no package manager). Install manually: ${missing[*]}"
      exit 1
    fi
    if confirm "Install missing dependencies (${missing[*]}) via ${PKG_MGR}?"; then
      pkg_install "${missing[@]}" || { error "Dependency installation failed."; exit 1; }
    else
      error "Required dependencies missing; cannot continue."
      exit 1
    fi
    # Re-resolve compose after install.
    if docker compose version >/dev/null 2>&1; then DOCKER_COMPOSE="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then DOCKER_COMPOSE="docker-compose"; fi
  fi

  [ -n "$DOCKER_COMPOSE" ] || { error "docker compose not available."; exit 1; }
  docker info >/dev/null 2>&1 || warn "Docker daemon not reachable as current user; some steps may need sudo/root."
}
