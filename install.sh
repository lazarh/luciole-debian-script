#!/usr/bin/env bash
#
# luciole-debian-script - install the Luciole file manager on Debian.
#
# Luciole is a native Wayland file manager from the Noctalia developers. It is
# built from source and installed under /usr/local, exactly as the upstream
# documentation describes:
#   https://github.com/noctalia-dev/luciole/blob/main/docs/user/installation.md
#
# Debian 13 (trixie) ships wayland-protocols 1.44, but Luciole requires 1.49 or
# newer. On such releases this script fetches a newer wayland-protocols build
# from the Debian pool (it is architecture-independent data, not a library) or,
# as a fallback, builds the upstream release into /usr/local.
#
set -euo pipefail

LUCIOLE_REPO="${LUCIOLE_REPO:-https://github.com/noctalia-dev/luciole.git}"
WAYLAND_PROTOCOLS_MIN="1.49"
WAYLAND_PROTOCOLS_SOURCE_VERSION="1.50"
WAYLAND_PROTOCOLS_POOL="https://deb.debian.org/debian/pool/main/w/wayland-protocols/"
WAYLAND_PROTOCOLS_RELEASES="https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases"

ORIG_DIR="$PWD"
TMP_DIRS=()

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_BLUE=$'\033[1;34m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_RED=$'\033[1;31m'
else
  C_RESET=""
  C_BOLD=""
  C_BLUE=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
fi

info() { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%s[error]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die() {
  error "$*"
  exit 1
}

step() { # number label
  printf '\n%s[%s] %s%s\n' "$C_BOLD$C_BLUE" "$1" "$2" "$C_RESET"
}

# ---------------------------------------------------------------------------
# Temporary directories
# ---------------------------------------------------------------------------

make_tmp_dir() { # variable name
  local dir_path
  dir_path="$(mktemp -d "${TMPDIR:-/tmp}/luciole-debian-script.XXXXXX")"
  TMP_DIRS+=("$dir_path")
  printf -v "$1" '%s' "$dir_path"
}

cleanup() {
  local dir
  for dir in "${TMP_DIRS[@]}"; do
    if [[ -n "$dir" && -d "$dir" ]]; then
      rm -rf -- "$dir" || true
    fi
  done
  cd "$ORIG_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Privileges and users
# ---------------------------------------------------------------------------

sudo_cmd() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

ensure_privileges() {
  [[ $EUID -eq 0 ]] && return 0
  command -v sudo >/dev/null 2>&1 || die "sudo is required to install system packages"
  sudo -v || die "could not obtain sudo privileges"
}

target_user() {
  if [[ $EUID -eq 0 ]]; then
    printf '%s\n' "${SUDO_USER:-}"
  else
    printf '%s\n' "${USER:-$(id -un)}"
  fi
}

run_as_target_user() {
  local user
  user="$(target_user)"
  if [[ $EUID -eq 0 && -n "$user" ]]; then
    sudo -H -u "$user" -- "$@"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

version_ge() { # $1 >= $2
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

apt_has() {
  apt-cache show "$1" >/dev/null 2>&1
}

apt_update() {
  info "refreshing package lists"
  sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get update
}

apt_install() { # packages...
  local available=() missing=() package
  for package in "$@"; do
    if apt_has "$package"; then
      available+=("$package")
    else
      missing+=("$package")
    fi
  done
  if ((${#missing[@]} > 0)); then
    warn "not available in this release, skipping: ${missing[*]}"
  fi
  ((${#available[@]} > 0)) || return 0
  info "installing: ${available[*]}"
  sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y "${available[@]}"
}

confirm() { # prompt, default no
  [[ -t 0 ]] || return 1
  local reply
  read -r -p "$1" reply || return 1
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

prompt_yes() { # prompt, default yes
  [[ -t 0 ]] || return 0
  local reply
  read -r -p "$1" reply || return 0
  [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

maybe_skip() { # step description
  [[ $ASK_STEP -eq 1 ]] || return 0
  prompt_yes "Run step: $1? [Y/n] "
}

# ---------------------------------------------------------------------------
# Debian detection
# ---------------------------------------------------------------------------

detect_debian() {
  [[ -r /etc/os-release ]] || die "cannot read /etc/os-release; this script targets Debian"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "this script targets Debian (detected ID=${ID:-unknown})"
  case "${VERSION_CODENAME:-}" in
    trixie | forky | sid | testing | unstable | "") ;;
    *) die "unsupported Debian release '${VERSION_CODENAME}' (Debian 13 'trixie' or newer is required)" ;;
  esac
  info "Debian ${VERSION_CODENAME:-unknown} detected"
}

# ---------------------------------------------------------------------------
# Step 1: system dependencies
# ---------------------------------------------------------------------------

BUILD_PACKAGES=(
  build-essential g++ pkg-config meson ninja-build
  git curl wget python3 just
  libwayland-dev libwayland-bin
  libegl1-mesa-dev libgles2-mesa-dev
  libglib2.0-dev
  libfreetype-dev libfontconfig1-dev
  libcairo2-dev libpango1.0-dev libharfbuzz-dev libxkbcommon-dev
  libgdk-pixbuf-2.0-dev librsvg2-dev libpng-dev
  libarchive-dev liblzma-dev libacl1-dev
  libcurl4-gnutls-dev libxml2-dev
  libtomlplusplus-dev nlohmann-json3-dev libstb-dev
)

RUNTIME_PACKAGES=(
  shared-mime-info gsettings-desktop-schemas dconf-gsettings-backend
  adwaita-icon-theme fonts-noto-core
  gvfs gvfs-backends gvfs-daemons
  xdg-utils
)

HELPER_PACKAGES=(
  ffmpeg ffmpegthumbnailer poppler-utils 7zip xdg-terminal-exec glib-networking
)

ensure_just() {
  command -v just >/dev/null 2>&1 && return 0
  warn "just is not available via apt; installing it with cargo"
  if ! command -v cargo >/dev/null 2>&1; then
    info "installing a minimal Rust toolchain with rustup"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
  fi
  # shellcheck disable=SC1091
  [[ -f "$HOME/.cargo/env" ]] && . "$HOME/.cargo/env"
  cargo install --locked just
  command -v just >/dev/null 2>&1 || die "just is still not available"
}

install_dependencies() {
  step "1/4" "System dependencies"
  apt_update
  info "installing build and required runtime packages"
  apt_install "${BUILD_PACKAGES[@]}" "${RUNTIME_PACKAGES[@]}"
  ensure_just
  command -v meson >/dev/null 2>&1 || die "meson is not available after installing dependencies"
  command -v pkg-config >/dev/null 2>&1 || die "pkg-config is not available after installing dependencies"
  ok "build dependencies are in place"
}

# ---------------------------------------------------------------------------
# Step 2: wayland-protocols >= 1.49
# ---------------------------------------------------------------------------

wp_installed_version() {
  pkg-config --modversion wayland-protocols 2>/dev/null || true
}

apt_candidate_version() { # package
  local version
  version="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
  if [[ -z "$version" || "$version" == "(none)" ]]; then
    return 0
  fi
  printf '%s' "${version%%-*}"
}

print_wayland_protocols_help() {
  cat <<'EOF'
Could not obtain a new enough wayland-protocols automatically. Do it by hand:

  # option 1: newest architecture-independent build from the Debian pool
  curl -fsSLO https://deb.debian.org/debian/pool/main/w/wayland-protocols/
  # then download wayland-protocols_<ver>_all.deb from that listing and run:
  sudo apt-get install ./wayland-protocols_<ver>_all.deb

  # option 2: build the upstream release into /usr/local
  ver=1.50
  curl -fsSLO "https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/$ver/downloads/wayland-protocols-$ver.tar.xz"
  tar -xJf "wayland-protocols-$ver.tar.xz"
  cd "wayland-protocols-$ver"
  meson setup build --prefix=/usr/local --buildtype=release
  ninja -C build
  sudo ninja -C build install
  export PKG_CONFIG_PATH="/usr/local/share/pkgconfig:${PKG_CONFIG_PATH:-}"

wayland-protocols contains only XML protocol descriptions and pkg-config data,
so installing a newer one alongside the release's copy is safe.
EOF
}

install_wayland_protocols_from_pool() {
  local listing deb version url dir
  info "the release's wayland-protocols is too old; fetching a newer build from the Debian pool"
  listing="$(curl -fsSL --max-time 30 "$WAYLAND_PROTOCOLS_POOL" || true)"
  [[ -n "$listing" ]] || return 1
  deb="$(printf '%s\n' "$listing" \
    | grep -oE 'wayland-protocols_[0-9][0-9.]*-[0-9]+_all\.deb' \
    | sort -Vu \
    | tail -n1)" || true
  [[ -n "$deb" ]] || return 1
  version="${deb#wayland-protocols_}"
  version="${version%_all.deb}"
  version="${version%%-*}"
  if ! version_ge "$version" "$WAYLAND_PROTOCOLS_MIN"; then
    warn "the Debian pool has no wayland-protocols >= $WAYLAND_PROTOCOLS_MIN (newest: $version)"
    return 1
  fi
  url="${WAYLAND_PROTOCOLS_POOL}${deb}"
  make_tmp_dir dir
  info "downloading $url"
  if ! curl -fsSL --max-time 120 "$url" -o "$dir/$deb"; then
    warn "download failed"
    return 1
  fi
  sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y "$dir/$deb"
}

install_wayland_protocols_from_source() {
  local version="$WAYLAND_PROTOCOLS_SOURCE_VERSION" dir url
  info "falling back to building wayland-protocols $version into /usr/local"
  make_tmp_dir dir
  url="$WAYLAND_PROTOCOLS_RELEASES/$version/downloads/wayland-protocols-$version.tar.xz"
  if ! curl -fsSL --max-time 120 "$url" -o "$dir/wayland-protocols.tar.xz"; then
    warn "could not download $url"
    print_wayland_protocols_help
    return 1
  fi
  tar -xJf "$dir/wayland-protocols.tar.xz" -C "$dir"
  (
    cd "$dir/wayland-protocols-$version"
    meson setup build --prefix=/usr/local --buildtype=release
    ninja -C build
    sudo_cmd ninja -C build install
  )
  export PKG_CONFIG_PATH="/usr/local/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
}

ensure_wayland_protocols() {
  step "2/4" "wayland-protocols >= $WAYLAND_PROTOCOLS_MIN"
  command -v pkg-config >/dev/null 2>&1 \
    || die "pkg-config is missing; run the dependencies step first (--install-deps)"

  local current candidate
  current="$(wp_installed_version)"
  if [[ -n "$current" ]] && version_ge "$current" "$WAYLAND_PROTOCOLS_MIN"; then
    ok "wayland-protocols $current already satisfies the requirement"
    return 0
  fi
  [[ -n "$current" ]] && info "wayland-protocols $current is too old"

  candidate="$(apt_candidate_version wayland-protocols)"
  if [[ -n "$candidate" ]] && version_ge "$candidate" "$WAYLAND_PROTOCOLS_MIN"; then
    info "installing wayland-protocols $candidate from apt"
    apt_install wayland-protocols
  elif ! install_wayland_protocols_from_pool; then
    install_wayland_protocols_from_source || {
      error "could not make wayland-protocols $WAYLAND_PROTOCOLS_MIN available"
      return 1
    }
  fi

  current="$(wp_installed_version)"
  if [[ -z "$current" ]] || ! version_ge "$current" "$WAYLAND_PROTOCOLS_MIN"; then
    die "wayland-protocols >= $WAYLAND_PROTOCOLS_MIN is still not available"
  fi
  ok "wayland-protocols $current is available"
}

# ---------------------------------------------------------------------------
# Step 3: build and install Luciole
# ---------------------------------------------------------------------------

verify_installation() {
  local binary version_line
  binary="$(command -v luciole || true)"
  [[ -n "$binary" ]] || die "installation failed: the luciole binary is not on PATH"
  ok "installed binary: $binary"
  if version_line="$("$binary" --version 2>/dev/null | head -n1)"; then
    [[ -n "$version_line" ]] && ok "version: $version_line"
  else
    warn "the installed binary did not report a version; run 'luciole --version' manually"
  fi
  if [[ -f /usr/local/share/applications/dev.noctalia.luciole.desktop ]]; then
    ok "desktop entry installed"
  else
    warn "desktop entry dev.noctalia.luciole.desktop was not found"
  fi
}

build_and_install_luciole() {
  local dir wp
  wp="$(wp_installed_version)"
  if [[ -z "$wp" ]] || ! version_ge "$wp" "$WAYLAND_PROTOCOLS_MIN"; then
    ensure_wayland_protocols
  fi
  step "3/4" "Build and install Luciole"
  make_tmp_dir dir
  info "cloning $LUCIOLE_REPO"
  git clone --depth 1 "$LUCIOLE_REPO" "$dir/luciole"
  (
    cd "$dir/luciole"
    info "building the release configuration (this takes a while)"
    just build release
    info "installing under /usr/local"
    sudo_cmd env PATH="$PATH" just install release
  )
  verify_installation
}

# ---------------------------------------------------------------------------
# Step 4: optional helpers
# ---------------------------------------------------------------------------

install_helpers() {
  step "4/4" "Optional runtime helpers"
  apt_install "${HELPER_PACKAGES[@]}"
  ok "helpers enable video/PDF thumbnails, encrypted 7z input, terminal actions and TLS"
}

# ---------------------------------------------------------------------------
# Optional: default file manager and FileChooser portal
# ---------------------------------------------------------------------------

set_default_file_manager() {
  step "opt" "Set Luciole as the default file manager"
  local user
  user="$(target_user)"
  if [[ -z "$user" ]]; then
    warn "cannot determine the target user; run this as your normal user"
    return 0
  fi
  command -v xdg-mime >/dev/null 2>&1 || apt_install xdg-utils
  run_as_target_user xdg-mime default dev.noctalia.luciole.desktop inode/directory
  ok "Luciole now handles inode/directory for $user"
  info "undo with: xdg-mime default <other-file-manager>.desktop inode/directory"
}

enable_filechooser_portal() {
  step "opt" "Use Luciole as the FileChooser portal backend"
  local conf="/etc/xdg/xdg-desktop-portal/portals.conf"
  if [[ ! -f /usr/local/share/xdg-desktop-portal/portals/luciole.portal ]]; then
    warn "Luciole's portal file is missing; install Luciole first"
  fi
  sudo_cmd mkdir -p /etc/xdg/xdg-desktop-portal
  if [[ -f "$conf" && ! -f "$conf.backup" ]]; then
    sudo_cmd cp -a "$conf" "$conf.backup"
    info "backed up $conf to $conf.backup"
  fi
  sudo_cmd python3 - "$conf" <<'PY'
import sys

path = sys.argv[1]
key = "org.freedesktop.impl.portal.FileChooser"
entry = f"{key}=luciole;gtk"

try:
    with open(path, "r", encoding="utf-8") as handle:
        lines = handle.read().splitlines()
except FileNotFoundError:
    lines = []

kept = [line for line in lines if not line.strip().startswith(key + "=")]

try:
    index = next(i for i, line in enumerate(kept) if line.strip() == "[preferred]")
except StopIteration:
    if kept and kept[-1].strip():
        kept.append("")
    kept.extend(["[preferred]", entry])
else:
    kept.insert(index + 1, entry)

with open(path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(kept) + "\n")
PY
  ok "wrote $conf"
  local uid
  uid="$(id -u "$(target_user)" 2>/dev/null || true)"
  if [[ -n "$uid" ]] && run_as_target_user env "XDG_RUNTIME_DIR=/run/user/$uid" \
    systemctl --user restart xdg-desktop-portal 2>/dev/null; then
    ok "restarted xdg-desktop-portal"
  else
    info "restart the portal to apply: systemctl --user restart xdg-desktop-portal"
  fi
}

# ---------------------------------------------------------------------------
# Maintenance
# ---------------------------------------------------------------------------

upgrade_luciole() {
  step "upgrade" "Upgrade Luciole from the latest source"
  build_and_install_luciole
}

uninstall_luciole() {
  step "uninstall" "Remove Luciole"
  confirm "Remove Luciole from /usr/local? [y/N] " || {
    info "cancelled"
    return 0
  }
  command -v just >/dev/null 2>&1 || die "just is missing; run the dependencies step first (--install-deps)"
  command -v meson >/dev/null 2>&1 || die "meson is missing; run the dependencies step first (--install-deps)"
  local dir
  make_tmp_dir dir
  info "cloning $LUCIOLE_REPO to generate the uninstall manifest"
  git clone --depth 1 "$LUCIOLE_REPO" "$dir/luciole"
  (
    cd "$dir/luciole"
    just configure release
    sudo_cmd env PATH="$PATH" just uninstall release
  )
  ok "Luciole files were removed from /usr/local"
  warn "apt packages and wayland-protocols installed earlier were left in place"
}

# ---------------------------------------------------------------------------
# Full install
# ---------------------------------------------------------------------------

post_install() {
  step "done" "Luciole is installed"
  info "start it from a Wayland session with: luciole"
  info "optional: ./install.sh --set-default   (default file manager)"
  info "optional: ./install.sh --enable-portal (FileChooser portal backend)"
  if [[ -t 0 ]]; then
    if confirm "Set Luciole as the default file manager? [y/N] "; then
      set_default_file_manager
    fi
    if confirm "Use Luciole as the FileChooser portal backend? [y/N] "; then
      enable_filechooser_portal
    fi
  fi
}

run_all() {
  if maybe_skip "install system dependencies"; then
    install_dependencies
  fi
  if maybe_skip "ensure wayland-protocols"; then
    ensure_wayland_protocols
  fi
  if maybe_skip "build and install Luciole"; then
    build_and_install_luciole
  fi
  if [[ $WITH_HELPERS -eq 1 ]] && maybe_skip "install optional helpers"; then
    install_helpers
  fi
  post_install
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------

print_menu() {
  cat <<'EOF'

Luciole installer

  Core steps
    1) System dependencies (build and runtime packages)
    2) wayland-protocols >= 1.49 (needed on Debian 13)
    3) Build and install Luciole

  Optional
    4) Runtime helpers (thumbnails, archives, terminal actions)
    5) Set Luciole as the default file manager
    6) Use Luciole as the FileChooser portal backend

  Maintenance
    7) Upgrade Luciole from the latest source
    8) Uninstall Luciole

    a) All core steps
    q) Quit

EOF
}

menu_loop() {
  local selection token want_deps want_wp want_luciole want_helpers want_default
  local want_portal want_upgrade want_uninstall bad
  while true; do
    print_menu
    if ! read -r -p "Selection (comma or space separated): " selection; then
      return 0
    fi
    [[ -z "${selection//[[:space:]]/}" ]] && return 0
    selection="${selection//,/ }"
    want_deps=0 want_wp=0 want_luciole=0 want_helpers=0
    want_default=0 want_portal=0 want_upgrade=0 want_uninstall=0 bad=0
    for token in $selection; do
      case "${token,,}" in
        1 | deps) want_deps=1 ;;
        2 | wp | wayland | wayland-protocols) want_wp=1 ;;
        3 | luciole) want_luciole=1 ;;
        4 | helpers) want_helpers=1 ;;
        5 | default | default-fm) want_default=1 ;;
        6 | portal) want_portal=1 ;;
        7 | upgrade) want_upgrade=1 ;;
        8 | uninstall | remove) want_uninstall=1 ;;
        a | all) want_deps=1 want_wp=1 want_luciole=1 want_helpers=1 ;;
        q | quit) return 0 ;;
        *)
          warn "unknown selection: $token"
          bad=1
          ;;
      esac
    done
    if [[ $bad -eq 1 ]]; then
      continue
    fi
    if [[ $want_deps -eq 1 ]]; then install_dependencies; fi
    if [[ $want_wp -eq 1 ]]; then ensure_wayland_protocols; fi
    if [[ $want_luciole -eq 1 ]]; then build_and_install_luciole; fi
    if [[ $want_helpers -eq 1 ]]; then install_helpers; fi
    if [[ $want_default -eq 1 ]]; then set_default_file_manager; fi
    if [[ $want_portal -eq 1 ]]; then enable_filechooser_portal; fi
    if [[ $want_upgrade -eq 1 ]]; then upgrade_luciole; fi
    if [[ $want_uninstall -eq 1 ]]; then uninstall_luciole; fi
  done
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Luciole installer for Debian

Usage: ./install.sh [options]

Without options the script runs the full install: system dependencies,
wayland-protocols, Luciole (built from source) and runtime helpers. Passing any
of the action flags below switches off that default and runs only what was
asked for.

Core steps
  --install-deps        Install build and runtime dependencies and make sure
                        wayland-protocols >= 1.49 is available
  --install-luciole     Build and install Luciole from source

Optional
  --install-helpers     Install runtime helpers (thumbnails, archives,
                        terminal actions, TLS)
  --no-helpers          Skip the runtime helpers in a full install
  --set-default         Set Luciole as the default file manager
  --enable-portal       Use Luciole as the FileChooser portal backend

Maintenance
  --upgrade             Rebuild and reinstall Luciole from the latest source
  --uninstall           Remove Luciole from /usr/local

Interaction
  --menu                Show the interactive component menu
  --ask-step            Ask before each step of a full install
  -h, --help            Show this help

Examples
  ./install.sh                              # full install
  ./install.sh --menu                       # interactive menu
  ./install.sh --ask-step                   # prompt before every step
  ./install.sh --install-luciole            # only build and install
  ./install.sh --set-default --enable-portal
  ./install.sh --upgrade                    # rebuild from latest source
EOF
}

main() {
  local show_menu=0
  local opt_deps=0 opt_luciole=0 opt_helpers=0 opt_default=0 opt_portal=0
  local opt_upgrade=0 opt_uninstall=0 has_action=0

  WITH_HELPERS=1
  ASK_STEP=0

  while (($# > 0)); do
    case "$1" in
      --menu) show_menu=1 ;;
      --ask-step) ASK_STEP=1 ;;
      --no-helpers) WITH_HELPERS=0 ;;
      --install-deps) opt_deps=1 has_action=1 ;;
      --install-luciole) opt_luciole=1 has_action=1 ;;
      --install-helpers) opt_helpers=1 has_action=1 ;;
      --set-default) opt_default=1 has_action=1 ;;
      --enable-portal) opt_portal=1 has_action=1 ;;
      --upgrade) opt_upgrade=1 has_action=1 ;;
      --uninstall) opt_uninstall=1 has_action=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        error "unknown option: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done

  detect_debian
  ensure_privileges

  if [[ $show_menu -eq 1 ]]; then
    menu_loop
    return 0
  fi

  if [[ $has_action -eq 0 ]]; then
    run_all
    return 0
  fi

  if [[ $opt_deps -eq 1 ]]; then
    install_dependencies
    ensure_wayland_protocols
  fi
  if [[ $opt_luciole -eq 1 ]]; then build_and_install_luciole; fi
  if [[ $opt_helpers -eq 1 ]]; then install_helpers; fi
  if [[ $opt_default -eq 1 ]]; then set_default_file_manager; fi
  if [[ $opt_portal -eq 1 ]]; then enable_filechooser_portal; fi
  if [[ $opt_upgrade -eq 1 ]]; then upgrade_luciole; fi
  if [[ $opt_uninstall -eq 1 ]]; then uninstall_luciole; fi
}

main "$@"
