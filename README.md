# Luciole + Debian Installation Script

Automated installation script for [Luciole](https://github.com/noctalia-dev/luciole), the native Wayland file manager from the Noctalia developers, on Debian-based systems.

## Overview

This script provides a complete installation workflow for:

- **Luciole**: a native Wayland file manager built on Noctalia's rendering and controls, with no Qt or GTK widget dependency. It uses a static internal copy of the Noctalia UI library, so the Noctalia shell is **not** required.

The script installs missing packages, handles a `wayland-protocols` version problem on Debian 13, builds Luciole from source with `just` and Meson, and installs it under `/usr/local` exactly as described in the [upstream installation guide](https://github.com/noctalia-dev/luciole/blob/main/docs/user/installation.md).

> Luciole is under active development. Upstream ships an AUR package for Arch Linux; on Debian, building from source is currently the only option.

## Prerequisites

- **Debian 13 (Trixie) or later** (forky/sid also work)
- Root/sudo access
- Internet connection
- An existing Wayland session for running Luciole (any compositor: niri, sway, GNOME, KDE, ...). Noctalia is not required.
- `x86_64` or `arm64` are the architectures upstream verifies; other architectures build from source but are not verified by upstream

Unlike the [niri + Noctalia installer](https://github.com/lazarh/niri-noctalia-debian-script), this script does not install a compositor or desktop shell. It adds Luciole to a session you already have.

## Usage

### Basic installation

```
chmod +x install.sh
./install.sh
```

With no arguments the script runs the full install: system dependencies, `wayland-protocols`, Luciole, and the runtime helpers.

### Selecting components

Passing **any** `--install-*`, `--set-default`, `--enable-portal`, `--upgrade` or `--uninstall` flag switches off the "install everything" default, so the script runs only what you asked for:

```
./install.sh --install-luciole            # only build and install Luciole
./install.sh --install-helpers            # only the runtime helpers
./install.sh --set-default --enable-portal
```

`--ask-step` and `--no-helpers` are orthogonal: they can be combined with the default or with individual flags.

### Interactive menu

```
./install.sh --menu
```

Shows a numbered menu:

- Core steps (1-3): system dependencies, `wayland-protocols`, Luciole
- Optional (4-6): runtime helpers, default file manager, FileChooser portal
- Maintenance (7-8): upgrade, uninstall
- `a` runs all core steps, `q` quits

Selections may be comma or space separated (`1,3` or `1 3`).

### Interactive mode

```
./install.sh --ask-step
```

Prompts before each step of a full install, so you can skip components that are already present.

### Command-line options

```
# Core
./install.sh --install-deps       # dependencies + wayland-protocols
./install.sh --install-luciole    # build and install Luciole

# Optional
./install.sh --install-helpers    # runtime helpers
./install.sh --no-helpers         # full install without helpers
./install.sh --set-default        # default file manager for inode/directory
./install.sh --enable-portal      # FileChooser portal backend

# Maintenance
./install.sh --upgrade            # rebuild from the latest source
./install.sh --uninstall          # remove Luciole from /usr/local

# Interaction
./install.sh --menu
./install.sh --ask-step
```

For the full list, run:

```
./install.sh --help
```

## Installation steps

### [1/4] System dependencies

Installs, via apt:

- Build tools: `build-essential`, `g++`, `pkg-config`, `meson`, `ninja-build`, `python3`, `just`
- Wayland: `libwayland-dev`, `libwayland-bin` (for `wayland-scanner`)
- Rendering and text: `libegl1-mesa-dev`, `libgles2-mesa-dev`, `libfreetype-dev`, `libfontconfig1-dev`, `libcairo2-dev`, `libpango1.0-dev`, `libharfbuzz-dev`, `libxkbcommon-dev`
- GLib/GIO, images, archives and data: `libglib2.0-dev`, `libgdk-pixbuf-2.0-dev`, `librsvg2-dev`, `libpng-dev`, `libarchive-dev`, `liblzma-dev`, `libacl1-dev`, `libcurl4-gnutls-dev`, `libxml2-dev`, `libtomlplusplus-dev`, `nlohmann-json3-dev`, `libstb-dev`
- Required runtime integration: `shared-mime-info`, `gsettings-desktop-schemas`, `dconf-gsettings-backend`, `adwaita-icon-theme`, `fonts-noto-core`, `gvfs`, `gvfs-backends`, `gvfs-daemons`, `xdg-utils`

If the release does not carry `just`, the script falls back to `cargo install just` after installing a minimal Rust toolchain with rustup.

### [2/4] wayland-protocols >= 1.49

Luciole's `meson.build` requires `wayland-protocols` 1.49 or newer. Debian 13 ships 1.44, which is too old. The script installs the newest appropriate build from the Debian pool (see [wayland-protocols on Debian 13](#wayland-protocols-on-debian-13)) or, as a fallback, builds the upstream release into `/usr/local`.

### [3/4] Build and install Luciole

- Clones [noctalia-dev/luciole](https://github.com/noctalia-dev/luciole)
- Builds with `just build release` (Meson, release build type with LTO)
- Installs with `sudo just install release` under `/usr/local`
- Verifies the binary, version and desktop entry

### [4/4] Runtime helpers (optional)

Installs `ffmpeg`, `ffmpegthumbnailer`, `poppler-utils`, `7zip`, `xdg-terminal-exec` and `glib-networking`, which enable video and PDF thumbnails, encrypted 7z archives, terminal actions and TLS for network locations. Skip them with `--no-helpers`; ordinary local browsing works without them.

Builds happen in `mktemp -d` directories that are registered with an `EXIT` trap and removed when the script finishes, including after a failure or Ctrl-C.

## Optional components

### Set as default file manager (`--set-default`)

Upstream intentionally does not register Luciole as the default handler for directories. This flag runs, for the invoking user:

```
xdg-mime default dev.noctalia.luciole.desktop inode/directory
```

Undo it by pointing `inode/directory` at another file manager's desktop file.

### FileChooser portal backend (`--enable-portal`)

Registers Luciole as the `xdg-desktop-portal` FileChooser backend by writing, idempotently:

```
[preferred]
org.freedesktop.impl.portal.FileChooser=luciole;gtk
```

into `/etc/xdg/xdg-desktop-portal/portals.conf` (backed up first as `portals.conf.backup`). `gtk` stays as a fallback. The portal is restarted for the invoking user when possible; otherwise restart it manually:

```
systemctl --user restart xdg-desktop-portal
```

Luciole installs its portal file under `/usr/local/share/xdg-desktop-portal/portals/`. Debian's default `XDG_DATA_DIRS` includes `/usr/local/share`, so `xdg-desktop-portal` discovers it without extra configuration.

Without this step, file dialogs from other applications keep using the session's default backend. Luciole's own file chooser keeps working in either case.

## Upgrading

```
./install.sh --upgrade
```

Clones the latest source and rebuilds and reinstalls Luciole. Your settings in `~/.config/luciole/` are not touched.

Re-running `./install.sh` also refreshes the apt packages.

## Uninstalling

```
./install.sh --uninstall
```

Re-clones the latest source, configures it, and runs `ninja uninstall`, which removes the files listed in the current install manifest from `/usr/local`. It asks for confirmation and refuses to run non-interactively.

Notes:

- If the installed version differs from the latest source, files that only exist in the older version may stay behind. Check `/usr/local/bin/luciole` and `/usr/local/share/luciole` afterwards.
- Run the dependencies step first if `just` or `meson` are gone.
- apt packages and `wayland-protocols` installed for the build are **not** removed; that is your decision.

## wayland-protocols on Debian 13

Luciole requires `wayland-protocols` 1.49 or newer (`dependency('wayland-protocols', version: '>=1.49')` in `meson.build`). Debian 13 (Trixie) ships 1.44, and even `trixie-backports` currently has 1.47, so the release's own package cannot satisfy it. Debian 14 (forky/sid) ships 1.50 and works out of the box.

`wayland-protocols` contains only XML protocol descriptions and pkg-config data. It is architecture-independent (`all`) and has no dependencies, so a newer build can sit alongside the release's copy without conflict. The script:

1. Uses apt when the candidate version is 1.49 or newer (forky/sid).
2. Otherwise downloads the newest `wayland-protocols_*_all.deb` from the [Debian pool](https://deb.debian.org/debian/pool/main/w/wayland-protocols/) and installs it. dpkg records it as manually installed; apt will not silently replace it.
3. If the download fails, builds the upstream release into `/usr/local` and exports `PKG_CONFIG_PATH=/usr/local/share/pkgconfig` for the Luciole build.
4. If everything fails, prints the manual commands.

Manual fallback:

```
# install a newer architecture-independent build from the Debian pool
curl -fsSL https://deb.debian.org/debian/pool/main/w/wayland-protocols/ | grep _all.deb
sudo apt-get install ./wayland-protocols_<version>_all.deb

# or build the upstream release into /usr/local
ver=1.50
curl -fsSLO "https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/$ver/downloads/wayland-protocols-$ver.tar.xz"
tar -xJf "wayland-protocols-$ver.tar.xz" && cd "wayland-protocols-$ver"
meson setup build --prefix=/usr/local --buildtype=release
ninja -C build && sudo ninja -C build install
```

## Dependencies installed

### Build tools

- build-essential, g++, pkg-config, meson, ninja-build, python3
- git, curl, wget
- just (from apt, or `cargo install just` as a fallback)

### System libraries

- libwayland-dev, libwayland-bin
- libegl1-mesa-dev, libgles2-mesa-dev
- libglib2.0-dev
- libfreetype-dev, libfontconfig1-dev
- libcairo2-dev, libpango1.0-dev, libharfbuzz-dev, libxkbcommon-dev
- libgdk-pixbuf-2.0-dev, librsvg2-dev, libpng-dev
- libarchive-dev, liblzma-dev, libacl1-dev
- libcurl4-gnutls-dev, libxml2-dev
- libtomlplusplus-dev, nlohmann-json3-dev, libstb-dev

### Runtime integration

- shared-mime-info, adwaita-icon-theme, fonts-noto-core
- gsettings-desktop-schemas, dconf-gsettings-backend
- gvfs, gvfs-backends, gvfs-daemons (Trash, network locations)
- xdg-utils

### Optional helpers

- ffmpeg, ffmpegthumbnailer (video thumbnails)
- poppler-utils (PDF thumbnails and metadata)
- 7zip (encrypted 7z input)
- xdg-terminal-exec (terminal actions)
- glib-networking (TLS for secure network locations)

## Troubleshooting

### `just: command not found`

The dependencies step installs `just` from apt. If it fell back to cargo, source the environment in the current shell:

```
source ~/.cargo/env
```

### The build fails with compiler warnings

Luciole builds with `-Werror`. Debian 13 ships GCC 14; upstream currently verifies GCC/libstdc++ 16.2. If a newer/older compiler rejects a warning, install a newer toolchain (`gcc-15`, `g++-15`, `clang`) and point Meson at it:

```
CC=gcc-15 CXX=g++-15 ./install.sh --install-luciole
```

### `Dependency "wayland-protocols" not found` or version too old

Run the dependencies step (`./install.sh --install-deps`). If you installed the upstream fallback into `/usr/local`, make sure the build sees it:

```
export PKG_CONFIG_PATH=/usr/local/share/pkgconfig:${PKG_CONFIG_PATH:-}
```

### Thumbnails or terminal actions do not work

Install the helpers (`./install.sh --install-helpers`). Video thumbnails need `ffmpeg`, PDF needs `poppler-utils`, terminal actions need `xdg-terminal-exec` and a suitable terminal.

### The default file manager did not change

`xdg-mime` writes `~/.config/mimeapps.list` for the user that ran it. Check with:

```
xdg-mime query default inode/directory
```

Some desktop environments keep their own defaults and ignore `mimeapps.list`.

### File dialogs still use another backend

`--enable-portal` writes a system-wide `portals.conf`; the frontend reads it at startup. Restart it:

```
systemctl --user restart xdg-desktop-portal
```

A user-level `~/.config/xdg-desktop-portal/portals.conf` takes precedence over the system file.

### Uninstall left files behind

`ninja uninstall` removes what the current source tree's install manifest lists. Files added or renamed in an older or newer revision can remain. Remove `/usr/local/bin/luciole` and `/usr/local/share/luciole` manually if needed.

## Repository structure

```
.
├── install.sh    # Main installation script
└── README.md     # This file
```

## License

This installation script is provided as-is under the MIT license. Luciole itself is MIT-licensed; Niri, Noctalia and other components have their own licenses.

## Credits

- **Luciole**: [noctalia-dev/luciole](https://github.com/noctalia-dev/luciole)
- **Noctalia**: [noctalia-dev/noctalia](https://github.com/noctalia-dev/noctalia)
- This script follows the structure of [lazarh/niri-noctalia-debian-script](https://github.com/lazarh/niri-noctalia-debian-script)
