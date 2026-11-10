#!/bin/bash
set -Eeuo pipefail

clear
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
THE_STUFF="$SCRIPT_DIR/thestuff"
SUDOERS_DROPIN="/etc/sudoers.d/99-vile-install"
BUILD_ROOT=""
POLKIT_AGENT="/usr/libexec/polkit-mate-authentication-agent-1"

export PATH="$PATH:/usr/local/bin:$HOME/.local/bin"
export DEBIAN_FRONTEND=noninteractive

report_failure() {
    local exit_code=$?
    [[ "$BASHPID" == "$$" ]] || return 0
    echo "" >&2
    echo "ERROR: install.sh aborted at line ${1} (exit ${exit_code})." >&2
    echo "Failed command: ${2}" >&2
}
trap 'report_failure "$LINENO" "$BASH_COMMAND"' ERR

cleanup_install() {
    if [[ -f "$SUDOERS_DROPIN" ]]; then
        sudo rm -f "$SUDOERS_DROPIN" 2>/dev/null || true
    fi
    if [[ -n "$BUILD_ROOT" && -d "$BUILD_ROOT" ]]; then
        rm -rf "$BUILD_ROOT" 2>/dev/null || true
    fi
}
trap cleanup_install EXIT INT TERM

rewrite_shipped_home_paths() {
    local dest="$1"
    [[ -d "$dest" ]] || return 0
    local f
    while IFS= read -r f; do
        sed -i "s|/home/jor|${HOME}|g; s|__VILE_HOME__|${HOME}|g" "$f"
    done < <(grep -rlI -e '/home/jor' -e '__VILE_HOME__' "$dest" 2>/dev/null || true)
}

detect_cpu_arch() {
    case "$(uname -m)" in
        x86_64) echo "x86_64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)
            echo "ERROR: Unsupported architecture: $(uname -m)" >&2
            exit 1
            ;;
    esac
}

require_debian_trixie() {
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "debian" ]]; then
        echo "ERROR: This installer targets Debian Trixie (got ID=${ID:-unknown})."
        exit 1
    fi
    if [[ "${VERSION_CODENAME:-}" != "trixie" && "${VERSION_ID:-}" != "13" ]]; then
        echo "ERROR: This installer targets Debian 13 / Trixie (got VERSION_CODENAME=${VERSION_CODENAME:-} VERSION_ID=${VERSION_ID:-})."
        exit 1
    fi
}

ensure_apt_components() {
    echo "Ensuring apt components: main contrib non-free non-free-firmware..."
    local f
    shopt -s nullglob
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [[ -f "$f" ]] || continue
        if grep -qE '^[[:space:]]*deb co' "$f"; then
            sudo sed -i -E \
                -e 's/^(deb(-src)?[[:space:]]+[^#]*\<main\>)([[:space:]]*$)/\1 contrib non-free non-free-firmware/' \
                -e 's/^(deb(-src)?[[:space:]]+[^#]*\<main\>)([[:space:]]+contrib)([[:space:]]*$)/\1\3 non-free non-free-firmware/' \
                -e 's/^(deb(-src)?[[:space:]]+[^#]*\<main\>[[:space:]]+contrib[[:space:]]+non-free)([[:space:]]*$)/\1 non-free-firmware/' \
                "$f"
        fi
    done
    for f in /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue
        if grep -qE '^Components:' "$f"; then
            sudo python3 - "$f" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
needed = ["main", "contrib", "non-free", "non-free-firmware"]
out = []
for line in text.splitlines():
    if line.startswith("Components:"):
        comps = line.split(":", 1)[1].split()
        for c in needed:
            if c not in comps:
                comps.append(c)
        out.append("Components: " + " ".join(comps))
    else:
        out.append(line)
path.write_text("\n".join(out) + ("\n" if text.endswith("\n") else ""))
PY
        fi
    done
    shopt -u nullglob
}

enable_trixie_backports() {
    echo "Enabling trixie-backports..."
    sudo tee /etc/apt/sources.list.d/trixie-backports.sources >/dev/null <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
}

enable_i386_multiarch() {
    if dpkg --print-foreign-architectures | grep -qx i386; then
        echo "i386 multiarch already enabled."
        return 0
    fi
    echo "Enabling i386 multiarch (NVIDIA 32-bit libs)..."
    sudo dpkg --add-architecture i386
}

install_backports_kernel() {
    echo "Installing linux-image/headers from trixie-backports..."
    sudo apt-get install -y -t trixie-backports linux-image-amd64 linux-headers-amd64
}

enable_dux_niri_repo() {
    echo "Adding Dux Labs repo for niri..."
    sudo install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://download.opensuse.org/repositories/home:duxlabs-dev:dux-repo/Debian_13/Release.key \
        | sudo gpg --dearmor --yes -o /etc/apt/keyrings/home-duxlabs-dev-dux-repo.gpg
    echo "deb [signed-by=/etc/apt/keyrings/home-duxlabs-dev-dux-repo.gpg] https://download.opensuse.org/repositories/home:/duxlabs-dev:/dux-repo/Debian_13/ /" \
        | sudo tee /etc/apt/sources.list.d/home-duxlabs-dev-dux-repo.list >/dev/null
}

install_librewolf() {
    echo "Installing LibreWolf via extrepo..."
    sudo apt-get install -y extrepo
    sudo extrepo enable librewolf
    sudo apt-get update
    sudo apt-get install -y librewolf
}

install_apt_packages() {
    echo "Installing Debian packages from aptlist.txt..."
    mapfile -t pkgs < <(grep -vE '^[[:space:]]*(#|$)' "$THE_STUFF/aptlist.txt")
    sudo apt-get install -y "${pkgs[@]}"
    # niri comes from Dux; xwayland-satellite is typically pulled as a dependency.
    sudo apt-get install -y niri
}

remove_stale_pywal_packages() {
    echo "Removing stale pywal/pywalfox pip packages if present..."
    local stale
    stale=$(pip3 list --format=freeze 2>/dev/null | cut -d= -f1 \
        | grep -ix -e pywal16 -e pywal -e pywalfox -e haishoku -e colorz || true)
    if [[ -n "$stale" ]]; then
        # shellcheck disable=SC2086
        sudo pip3 uninstall --break-system-packages -y $stale || true
    fi
    stale=$(pip3 list --user --format=freeze 2>/dev/null | cut -d= -f1 \
        | grep -ix -e pywal16 -e pywal -e pywalfox -e haishoku -e colorz || true)
    if [[ -n "$stale" ]]; then
        # shellcheck disable=SC2086
        pip3 uninstall --break-system-packages -y $stale || true
    fi
}

install_getnf() {
    if command -v getnf >/dev/null 2>&1; then
        echo "getnf already installed."
        return 0
    fi
    echo "Installing getnf from upstream..."
    local tmp
    tmp=$(mktemp -d)
    curl -fsSL "https://raw.githubusercontent.com/getnf/getnf/main/getnf" -o "$tmp/getnf"
    sudo install -Dm755 "$tmp/getnf" /usr/local/bin/getnf
    rm -rf "$tmp"
}

install_wifitui() {
    if command -v wifitui >/dev/null 2>&1; then
        echo "wifitui already installed."
        return 0
    fi
    echo "Installing wifitui from upstream release..."
    local tmp tag arch asset url stamp_dir
    tmp=$(mktemp -d)
    arch=$(detect_cpu_arch)
    tag=$(curl -fsSL "https://api.github.com/repos/shazow/wifitui/releases/latest" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")
    asset="wifitui-${tag#v}-linux-${arch}.tar.gz"
    url="https://github.com/shazow/wifitui/releases/download/${tag}/${asset}"
    curl -fsSL "$url" -o "$tmp/$asset"
    tar -xzf "$tmp/$asset" -C "$tmp"
    local bin
    bin=$(find "$tmp" -type f -name wifitui -print -quit)
    if [[ -z "$bin" ]]; then
        echo "ERROR: wifitui binary missing from release archive."
        exit 1
    fi
    sudo install -Dm755 "$bin" /usr/local/bin/wifitui
    stamp_dir="${XDG_CACHE_HOME:-$HOME/.cache}/vile/src"
    mkdir -p "$stamp_dir"
    echo "$tag" >"$stamp_dir/wifitui.installed"
    rm -rf "$tmp"
}

install_adw_gtk3() {
    echo "Installing adw-gtk3 theme from upstream release..."
    local tmp tag asset url
    tmp=$(mktemp -d)
    tag=$(curl -fsSL "https://api.github.com/repos/lassekongo83/adw-gtk3/releases/latest" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")
    # release assets are named like adw-gtk3v6.5.tar.xz
    asset="adw-gtk3${tag}.tar.xz"
    url="https://github.com/lassekongo83/adw-gtk3/releases/download/${tag}/${asset}"
    curl -fsSL "$url" -o "$tmp/$asset"
    tar -xJf "$tmp/$asset" -C "$tmp"
    sudo install -d /usr/share/themes
    if [[ -d "$tmp/adw-gtk3" ]]; then
        sudo rm -rf /usr/share/themes/adw-gtk3 /usr/share/themes/adw-gtk3-dark
        sudo cp -a "$tmp/adw-gtk3" /usr/share/themes/adw-gtk3
        sudo cp -a "$tmp/adw-gtk3-dark" /usr/share/themes/adw-gtk3-dark
    else
        # tarball may extract themes directly
        local theme_dir
        theme_dir=$(find "$tmp" -maxdepth 2 -type d -name 'adw-gtk3' -print -quit)
        [[ -n "$theme_dir" ]] || { echo "ERROR: adw-gtk3 theme dir missing from release archive."; exit 1; }
        sudo rm -rf /usr/share/themes/adw-gtk3 /usr/share/themes/adw-gtk3-dark
        sudo cp -a "$theme_dir" /usr/share/themes/adw-gtk3
        sudo cp -a "${theme_dir}-dark" /usr/share/themes/adw-gtk3-dark
    fi
    rm -rf "$tmp"
}

install_papirus_folders() {
    echo "Installing papirus-folders from upstream..."
    local src
    src="$THE_STUFF/papirus-folders"
    rm -rf "$src"
    git clone --depth 1 https://github.com/PapirusDevelopmentTeam/papirus-folders.git "$src"
    sudo make -C "$src" install
    mkdir -p "$HOME/.local/share/icons/"
    cp -a /usr/share/icons/Papirus "$HOME/.local/share/icons/Vile-Papirus"
    sed -i 's/^Name=.*/Name=Vile-Papirus/' "$HOME/.local/share/icons/Vile-Papirus/index.theme"
}

install_yazi() {
    if command -v yazi >/dev/null 2>&1; then
        echo "yazi already installed."
        return 0
    fi
    echo "Installing yazi from upstream .deb..."
    local tmp tag arch asset url
    tmp=$(mktemp -d)
    arch=$(detect_cpu_arch)
    tag=$(curl -fsSL "https://api.github.com/repos/sxyazi/yazi/releases/latest" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")
    case "$arch" in
        x86_64) asset="yazi-x86_64-unknown-linux-gnu.deb" ;;
        arm64) asset="yazi-aarch64-unknown-linux-gnu.deb" ;;
        *) echo "ERROR: no yazi .deb for arch $arch"; exit 1 ;;
    esac
    url="https://github.com/sxyazi/yazi/releases/download/${tag}/${asset}"
    curl -fsSL "$url" -o "$tmp/$asset"
    sudo apt-get install -y "$tmp/$asset"
    rm -rf "$tmp"
}

install_bluetui() {
    if command -v bluetui >/dev/null 2>&1; then
        echo "bluetui already installed."
        return 0
    fi
    echo "Installing bluetui from upstream release..."
    local tmp tag arch asset url
    tmp=$(mktemp -d)
    arch=$(detect_cpu_arch)
    tag=$(curl -fsSL "https://api.github.com/repos/pythops/bluetui/releases/latest" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")
    case "$arch" in
        x86_64) asset="bluetui-x86_64-linux-musl" ;;
        arm64) asset="bluetui-aarch64-linux-musl" ;;
        *) echo "ERROR: no bluetui binary for arch $arch"; exit 1 ;;
    esac
    url="https://github.com/pythops/bluetui/releases/download/${tag}/${asset}"
    curl -fsSL "$url" -o "$tmp/bluetui"
    chmod +x "$tmp/bluetui"
    sudo install -Dm755 "$tmp/bluetui" /usr/local/bin/bluetui
    rm -rf "$tmp"
}

ensure_rustup() {
    if [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck disable=SC1091
        source "$HOME/.cargo/env"
    fi
    if ! command -v rustup >/dev/null 2>&1; then
        echo "Installing rustup..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
        # shellcheck disable=SC1091
        source "$HOME/.cargo/env"
    fi
    rustup default stable
    if [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck disable=SC1091
        source "$HOME/.cargo/env"
    fi
    if ! command -v cargo >/dev/null 2>&1; then
        echo "ERROR: cargo is not on PATH after rustup."
        exit 1
    fi
}

configure_nvidia_modeset() {
    echo "Configuring nvidia-drm.modeset=1 for Wayland/niri..."
    local grub=/etc/default/grub
    if [[ ! -f "$grub" ]]; then
        echo "WARNING: $grub missing; skipping GRUB cmdline update."
        return 0
    fi
    sudo python3 - "$grub" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
params = ["nvidia-drm.modeset=1", "nvidia-drm.fbdev=1"]
def add_params(line: str) -> str:
    m = re.match(r'^(GRUB_CMDLINE_LINUX(?:_DEFAULT)?=)(["\'])(.*)\2\s*$', line)
    if not m:
        return line
    prefix, quote, value = m.group(1), m.group(2), m.group(3)
    tokens = value.split()
    for p in params:
        if p not in tokens:
            tokens.append(p)
    return f"{prefix}{quote}{' '.join(tokens)}{quote}"
out = [add_params(l) for l in text.splitlines()]
path.write_text("\n".join(out) + ("\n" if text.endswith("\n") else ""))
PY
    if command -v update-grub >/dev/null 2>&1; then
        sudo update-grub
    else
        sudo grub-mkconfig -o /boot/grub/grub.cfg
    fi
}

install_nvidia_stack() {
    echo "Installing NVIDIA open drivers from NVIDIA's apt repo..."
    local tmp keyring_deb
    tmp=$(mktemp -d)
    keyring_deb="cuda-keyring_1.1-1_all.deb"
    curl -fsSL "https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/${keyring_deb}" \
        -o "$tmp/$keyring_deb"
    sudo dpkg -i "$tmp/$keyring_deb"
    sudo apt-get update
    # Headers for the backports kernel so open DKMS can build.
    sudo apt-get install -y -t trixie-backports linux-headers-amd64
    sudo apt-get install -y nvidia-open
    echo "Installing 32-bit NVIDIA libs..."
    sudo apt-get install -y nvidia-driver-libs:i386
    configure_nvidia_modeset
    rm -rf "$tmp"
}

echo -e "\033[0;32m"
cat << "EOF"

Oh wow, I guess you're trying to install...

 __      ___ _     _____
 \ \    / (_) |   | ____|
  \ \  / / _| |   |  _|
   \ \/ / | | |___| |___
    \__/  |_|_____|_____|  desktop + dots

Nice...
EOF
sleep 1
echo -e "\033[0m"

sleep 0.5

cat << "EOF"
These dots sit on niri with viledesktop: a thin text bar, menus, tray,
notifications, wallpaper, and vilecolors theming (templates, GTK, foot,
niri, SDDM, LibreWolf via vilefox). No widget pile. The point is to stay
out of the way and keep you in the terminal.

The install script builds viledesktop from the sibling viledesktop/
tree, installs prerequisites, and copies configs. Meant for a minimal
Debian 13 (Trixie) install with no DE (Debian packages + Dux Labs niri +
a few trusted upstreams).

After considering all of this, you may proceed.
EOF
sleep 0.3

cat << "EOF"
Are you Ready to Install viledesktop and Vile's Dots?
EOF

PS3="Choose (but don't be a coward): "
options=("LETS DO THIS" "GET ME OUTTA HERE")

select opt in "${options[@]}"
do
    case $opt in
        "LETS DO THIS")
            echo "Nice..."
            sleep 1
            break
            ;;
        "GET ME OUTTA HERE")
            echo "Safe choice. No changes were made. Exiting..."
            sleep 1
            exit 0
            ;;
        *)
            echo "Invalid entry. Please pick 1 or 2."
            ;;
    esac
done
clear

echo "Starting the installation..."
echo "You may be asked for your password once or twice; the script keeps sudo alive afterward."
sleep 2
sudo -v

echo "Defaults:${USER} timestamp_timeout=180" | sudo tee "$SUDOERS_DROPIN" >/dev/null
sudo chmod 440 "$SUDOERS_DROPIN"
sudo visudo -cf "$SUDOERS_DROPIN" >/dev/null

while true; do
    sudo -n true
    sleep 60
    kill -0 "$$" || exit
done 2>/dev/null &

clear
require_debian_trixie

echo "Installing curl and build-essential first..."
sudo apt-get update
sudo apt-get install -y curl build-essential

echo "Checking network..."
if ! curl -fsSL --connect-timeout 8 -o /dev/null https://deb.debian.org/; then
    echo "ERROR: No network reachability to deb.debian.org. Configure network and try again."
    exit 1
fi

echo "Ensuring remaining bootstrap tools..."
sudo apt-get install -y git ca-certificates gnupg gpg wget

BUILD_ROOT=$(mktemp -d)

ensure_apt_components
enable_trixie_backports
enable_i386_multiarch
sudo apt-get update

install_backports_kernel
enable_dux_niri_repo
sudo apt-get update
install_librewolf
install_apt_packages
remove_stale_pywal_packages
install_getnf
install_wifitui
install_adw_gtk3
install_papirus_folders
install_yazi
install_bluetui

sudo chsh -s /usr/bin/fish "$USER"

ensure_rustup

VILE_ROOT="$SCRIPT_DIR/../viledesktop"
if [[ ! -f "$VILE_ROOT/Cargo.toml" ]]; then
    echo "ERROR: viledesktop workspace missing at $VILE_ROOT"
    exit 1
fi

echo "Building viledesktop..."
(cd "$VILE_ROOT" && cargo build --release --workspace)
mkdir -p "$HOME/.local/bin/"
for bin in vile viledaemon vilebar vilecolors vilewall vileshot vilefox; do
    if [[ ! -x "$VILE_ROOT/target/release/$bin" ]]; then
        echo "ERROR: viledesktop failed to build (missing target/release/$bin)."
        exit 1
    fi
    cp "$VILE_ROOT/target/release/$bin" "$HOME/.local/bin/$bin"
    chmod +x "$HOME/.local/bin/$bin"
done

mkdir -p "$HOME/.local/share/"

stamp_dir="${XDG_CACHE_HOME:-$HOME/.cache}/vile/src"
mkdir -p "$stamp_dir"
if git -C "$SCRIPT_DIR/.." rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$SCRIPT_DIR/.." rev-parse --short=12 HEAD:viledesktop \
        >"$stamp_dir/viledesktop.installed" 2>/dev/null || true
fi

mkdir -p "$HOME/Pictures/wallpaper/"
cp -r "$THE_STUFF/wallpaper/." "$HOME/Pictures/wallpaper/"

mkdir -p "$HOME/.config/"
cp -r "$THE_STUFF/.config/." "$HOME/.config/"

rewrite_shipped_home_paths "$HOME/.config"

mkdir -p "$HOME/Misc"
mkdir -p "$HOME/Pictures"
mkdir -p "$HOME/Downloads"
mkdir -p "$HOME/Videos"

cat << EOF > "$HOME/.config/gtk-3.0/bookmarks"
file://$HOME/Misc Misc
file://$HOME/Downloads Downloads
file://$HOME/Pictures Pictures
file://$HOME/Videos Videos
EOF

mkdir -p "$HOME/.local/bin/"
cp -r "$THE_STUFF/.local/bin/." "$HOME/.local/bin/"
chmod +x "$HOME/.local/bin/"*

mkdir -p "$HOME/.local/share/nwg-look"
cp -f "$THE_STUFF/.local/share/nwg-look/gsettings" "$HOME/.local/share/nwg-look/gsettings"
if command -v nwg-look >/dev/null 2>&1; then
    nwg-look -a
    nwg-look -x
fi
gsettings set org.gnome.desktop.interface icon-theme 'Vile-Papirus'
gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3-dark'
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'

if [[ ! -f "$HOME/.local/bin/niri-start-nvidia.sh" || ! -f "$HOME/.local/bin/niri-start-nonvidia.sh" ]]; then
    echo "ERROR: niri start scripts missing from ~/.local/bin after copy."
    exit 1
fi

fish -c "set -Ux TERMINAL foot"

SEED_WALL=""
for candidate in \
    "$HOME/Pictures/wallpaper/wallpaper_2.png" \
    "$HOME/Pictures/wallpaper/"*.png \
    "$HOME/Pictures/wallpaper/"*.jpg \
    "$HOME/Pictures/wallpaper/"*.jpeg; do
    if [[ -f "$candidate" ]]; then
        SEED_WALL="$candidate"
        break
    fi
done
if [[ -z "$SEED_WALL" ]]; then
    echo "ERROR: no seed wallpaper found under ~/Pictures/wallpaper/"
    exit 1
fi
if [[ ! -f "$HOME/.config/vile/colors/palettes/default.json" ]]; then
    echo "ERROR: missing shipped vilecolors recipe default.json"
    exit 1
fi
echo "Applying initial vilecolors palette from $(basename "$SEED_WALL")..."
python3 - <<'PY'
import json
from pathlib import Path
p = Path.home() / ".config/vile/config.json"
cfg = json.loads(p.read_text())
cfg["_install_saved_colors_apply_commands"] = cfg.get("colors_apply_commands", [])
cfg["_install_saved_colors_apply_commands_dark"] = cfg.get("colors_apply_commands_dark", [])
cfg["_install_saved_colors_apply_commands_light"] = cfg.get("colors_apply_commands_light", [])
cfg["colors_apply_commands"] = []
cfg["colors_apply_commands_dark"] = []
cfg["colors_apply_commands_light"] = []
p.write_text(json.dumps(cfg, indent=2) + "\n")
PY
"$HOME/.local/bin/vilecolors" --recipe default --img "$SEED_WALL"
python3 - <<'PY'
import json
from pathlib import Path
p = Path.home() / ".config/vile/config.json"
cfg = json.loads(p.read_text())
_vesktop_cp = "cp ~/.cache/wal/vesktop-clienttheme.css ~/.var/app/dev.vencord.Vesktop/config/vesktop/settings/quickCss.css"
cfg["colors_apply_commands"] = cfg.pop("_install_saved_colors_apply_commands", [
    "niri msg action load-config-file",
    "~/.local/bin/vile-refresh.sh",
    _vesktop_cp,
])
cfg["colors_apply_commands_dark"] = cfg.pop("_install_saved_colors_apply_commands_dark", [
    "niri msg action load-config-file",
    "~/.local/bin/vile-refresh.sh dark",
    _vesktop_cp,
])
cfg["colors_apply_commands_light"] = cfg.pop("_install_saved_colors_apply_commands_light", [
    "niri msg action load-config-file",
    "~/.local/bin/vile-refresh.sh light",
    _vesktop_cp,
])
p.write_text(json.dumps(cfg, indent=2) + "\n")
PY
SEED_WALL="$SEED_WALL" python3 - <<'PY'
import json
import os
from pathlib import Path
home = Path.home()
cfg = json.loads((home / ".config/vile/config.json").read_text())
mode = cfg.get("wallpaper", {}).get("mode", "fill")
img = Path(os.environ["SEED_WALL"]).expanduser().resolve()
if not img.is_file():
    raise SystemExit(f"seed wallpaper missing: {img}")
path = home / ".cache" / "vile" / "wallpaper.json"
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps({"image": str(img), "mode": mode}, indent=2) + "\n")
print(f"Seeded wallpaper state from {img.name} (mode={mode})")
PY
"$HOME/.local/bin/vilefox" install

if [[ -x "$HOME/.local/bin/folder-col.sh" ]]; then
    bash "$HOME/.local/bin/folder-col.sh" || true
fi

rm -f "$HOME/.config/gtk-4.0/gtk.css"
rm -f "$HOME/.config/gtk-4.0/gtk-dark.css"
rm -f "$HOME/.config/gtk-3.0/gtk.css"
rm -f "$HOME/.config/gtk-3.0/gtk-dark.css"

ln -s "$HOME/.cache/wal/gtk-css.css" "$HOME/.config/gtk-4.0/gtk.css"
ln -s "$HOME/.cache/wal/gtk-css.css" "$HOME/.config/gtk-4.0/gtk-dark.css"
ln -s "$HOME/.cache/wal/gtk-css.css" "$HOME/.config/gtk-3.0/gtk.css"
ln -s "$HOME/.cache/wal/gtk-css.css" "$HOME/.config/gtk-3.0/gtk-dark.css"

echo "Installing 0xProto Nerd Font..."
getnf -i "0xProto"
if ! getnf -l 2>/dev/null | grep -qi '0xProto'; then
    if ! find "$HOME/.local/share/fonts" "$HOME/.fonts" -iname '*0xProto*' 2>/dev/null | grep -q .; then
        echo "ERROR: getnf did not install 0xProto."
        exit 1
    fi
fi

clear
cat << "EOF"
To make sure your environment variables in your autostart script are configured properly, Please Share whether
or not you suffer from "I have an NVidia GPU and Use Linux" disorder.
EOF

PS3="DO YOU HAVE NVIDIA GPU?: "
options=("YES" "NO")

select opt in "${options[@]}"
do
    case $opt in
        "YES")
            echo "sorry..."
            rm -f "$HOME/.local/bin/niri-start-nonvidia.sh"
            mv "$HOME/.local/bin/niri-start-nvidia.sh" "$HOME/.local/bin/niri-start.sh"
            install_nvidia_stack
            sleep 1
            break
            ;;
        "NO")
            echo "lucky..."
            rm -f "$HOME/.local/bin/niri-start-nvidia.sh"
            mv "$HOME/.local/bin/niri-start-nonvidia.sh" "$HOME/.local/bin/niri-start.sh"
            sleep 1
            break
            ;;
        *)
            echo "Invalid entry. Please pick 1 or 2."
            ;;
    esac
done
chmod +x "$HOME/.local/bin/"*
clear

echo "Configuring SDDM, theme, and LibreWolf policies..."
sudo bash -c "
set -euo pipefail
systemctl enable sddm
systemctl set-default graphical.target
install -d /usr/share/sddm/themes /usr/local/lib/vile /etc/sddm.conf.d
install -d /usr/share/polkit-1/actions /etc/polkit-1/rules.d /etc/apt/apt.conf.d
cp -r \"$THE_STUFF/vile\" /usr/share/sddm/themes/
chown -R root:root /usr/share/sddm/themes/vile
install -m 644 \"$THE_STUFF/etc/sddm.conf.d/10-vile.conf\" /etc/sddm.conf.d/10-vile.conf
install -m 755 \"$THE_STUFF/usr/local/lib/vile/sddm-sync.sh\" /usr/local/lib/vile/sddm-sync.sh
install -m 644 \"$THE_STUFF/usr/share/polkit-1/actions/com.vile.sddm.sync.policy\" /usr/share/polkit-1/actions/com.vile.sddm.sync.policy
install -m 644 \"$THE_STUFF/etc/polkit-1/rules.d/10-vile-sddm.rules\" /etc/polkit-1/rules.d/10-vile-sddm.rules
SUDO_USER=\"$USER\" SUDO_UID=\"$(id -u)\" /usr/local/lib/vile/sddm-sync.sh
if [[ -f \"$THE_STUFF/etc/librewolf/policies.json\" ]]; then
    install -d /usr/local/share/vile /usr/local/lib/vile
    install -m 644 \"$THE_STUFF/etc/librewolf/policies.json\" /usr/local/share/vile/librewolf-policies.json
    install -m 755 \"$THE_STUFF/usr/local/lib/vile/librewolf-policy.sh\" /usr/local/lib/vile/librewolf-policy.sh
    install -m 755 \"$THE_STUFF/usr/local/lib/vile/librewolf-policy-hook.sh\" /usr/local/lib/vile/librewolf-policy-hook.sh
    install -m 644 \"$THE_STUFF/etc/apt/apt.conf.d/99vile-librewolf\" /etc/apt/apt.conf.d/99vile-librewolf
    if [[ -f \"$HOME/.local/share/vilefox/vilefox-signed.xpi\" ]]; then
        install -m 644 \"$HOME/.local/share/vilefox/vilefox-signed.xpi\" /usr/local/share/vile/vilefox-signed.xpi
    elif [[ -f \"$VILE_ROOT/vilefox/vilefox-signed.xpi\" ]]; then
        install -m 644 \"$VILE_ROOT/vilefox/vilefox-signed.xpi\" /usr/local/share/vile/vilefox-signed.xpi
    fi
    /usr/local/lib/vile/librewolf-policy.sh
fi
"

fish << EOF
if not contains "$HOME/.local/bin" \$fish_user_paths
    set -Ua fish_user_paths "$HOME/.local/bin"
end
set -Ux TERMINAL foot
EOF
clear

mkdir -p "$HOME/.config/xdg-desktop-portal-wlr"
cat << 'EOF' > "$HOME/.config/xdg-desktop-portal-wlr/wlroots"
[screencast]
chooser_cmd=slurp -f %o -or
chooser_type=simple
EOF

# sddm-theme-breeze pulls Plasma packages whose xdg-autostart entries (and some
# globally-enabled user units) otherwise start under niri: white xwaylandvideobridge
# window, kdeconnect, and ibus login notifications. Hidden overrides ship in
# thestuff/.config/autostart/; also pin im-config off and mask Plasma shells.
if command -v im-config >/dev/null 2>&1; then
    im-config -n none >/dev/null 2>&1 || true
fi
systemctl --user mask \
    plasma-plasmashell.service \
    plasma-ksmserver.service \
    plasma-kcminit.service >/dev/null 2>&1 || true

if [[ ! -x "$POLKIT_AGENT" ]]; then
    echo "WARNING: polkit agent missing at $POLKIT_AGENT (mate-polkit)."
fi

cat << "EOF"
This is the end of the script. Please reboot your computer.
EOF
