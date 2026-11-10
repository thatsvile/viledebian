#!/bin/bash
# Copy the current user's vile/wal SDDM colors + wallpaper into the system theme.
# Intended to run as root via pkexec (polkit) or during install via sudo.
set -euo pipefail

THEME_DIR="/usr/share/sddm/themes/vile"
THEME_CONF="$THEME_DIR/theme.conf"
THEME_USER_CONF="$THEME_DIR/theme.conf.user"
THEME_BG="$THEME_DIR/background.jpg"

resolve_user() {
    local uid name home
    if [[ -n "${PKEXEC_UID:-}" ]]; then
        uid=$PKEXEC_UID
    elif [[ -n "${SUDO_UID:-}" ]]; then
        uid=$SUDO_UID
    elif [[ -n "${SUDO_USER:-}" ]]; then
        name=$SUDO_USER
        uid=$(id -u "$name")
    else
        echo "vile-sddm-sync: must be invoked via pkexec or sudo" >&2
        exit 1
    fi

    if ! name=$(id -nu "$uid" 2>/dev/null); then
        echo "vile-sddm-sync: cannot resolve user for uid $uid" >&2
        exit 1
    fi
    if ! home=$(getent passwd "$uid" | cut -d: -f6) || [[ -z "$home" ]]; then
        echo "vile-sddm-sync: cannot resolve home for uid $uid" >&2
        exit 1
    fi

    printf '%s\t%s\t%s\n' "$uid" "$name" "$home"
}

# Normalize a wal-rendered sddm.conf so background is an absolute path the Qt6
# greeter can load (relative names like background.jpg often fail → white screen).
normalize_theme_conf() {
    local dest=$1
    local bg_abs="$THEME_BG"
    if grep -qE '^[[:space:]]*background=' "$dest"; then
        sed -i -E "s|^[[:space:]]*background=.*|background=${bg_abs}|" "$dest"
    elif grep -qE '^[[:space:]]*\[General\]' "$dest"; then
        sed -i -E "/^[[:space:]]*\[General\]/a background=${bg_abs}" "$dest"
    else
        printf '[General]\nbackground=%s\n' "$bg_abs" | cat - "$dest" >"${dest}.tmp"
        mv "${dest}.tmp" "$dest"
        chmod 644 "$dest"
    fi
}

if [[ "$(id -u)" -ne 0 ]]; then
    echo "vile-sddm-sync: must run as root" >&2
    exit 1
fi

IFS=$'\t' read -r _user_uid _user_name user_home < <(resolve_user)

wal_conf="$user_home/.cache/wal/sddm.conf"
wal_path_file="$user_home/.cache/wal/wal"

if [[ ! -f "$wal_conf" ]]; then
    echo "vile-sddm-sync: missing $wal_conf" >&2
    exit 1
fi
if [[ ! -f "$wal_path_file" ]]; then
    echo "vile-sddm-sync: missing $wal_path_file" >&2
    exit 1
fi
if [[ ! -d "$THEME_DIR" ]]; then
    echo "vile-sddm-sync: theme not installed at $THEME_DIR" >&2
    exit 1
fi

wallpaper=$(tr -d '\n' < "$wal_path_file")
if [[ -z "$wallpaper" ]]; then
    echo "vile-sddm-sync: empty wallpaper path in $wal_path_file" >&2
    exit 1
fi
if [[ "$wallpaper" != /* ]]; then
    echo "vile-sddm-sync: wallpaper path must be absolute" >&2
    exit 1
fi
wallpaper=$(readlink -f "$wallpaper")
if [[ ! -f "$wallpaper" ]]; then
    echo "vile-sddm-sync: wallpaper is not a regular file: $wallpaper" >&2
    exit 1
fi
# Ensure the invoking user can read the source (reject paths only root could open).
if ! runuser -u "$_user_name" -- test -r "$wallpaper"; then
    echo "vile-sddm-sync: wallpaper not readable by ${_user_name}: $wallpaper" >&2
    exit 1
fi

# Write both theme.conf and theme.conf.user. .user is the documented override;
# mirroring into theme.conf keeps colors correct if a greeter only reads the base file.
install -m 644 "$wal_conf" "$THEME_USER_CONF"
normalize_theme_conf "$THEME_USER_CONF"
install -m 644 "$THEME_USER_CONF" "$THEME_CONF"

install -m 644 "$wallpaper" "$THEME_BG"
chown root:root "$THEME_CONF" "$THEME_USER_CONF" "$THEME_BG"
