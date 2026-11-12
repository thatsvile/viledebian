#!/bin/bash
# apt Post-Invoke wrapper: re-merge vile LibreWolf policies only when a
# librewolf package was part of the current apt/dpkg transaction.
set -euo pipefail

FRAGMENT="/usr/local/share/vile/librewolf-policies.json"
POLICY_SH="/usr/local/lib/vile/librewolf-policy.sh"
HISTORY_LOG="/var/log/apt/history.log"

[[ -x "$POLICY_SH" ]] || exit 0
[[ -f "$FRAGMENT" ]] || exit 0

librewolf_present() {
    [[ -x /usr/bin/librewolf ]] \
        || [[ -d /usr/lib/librewolf ]] \
        || [[ -d /usr/share/librewolf ]]
}

# True when the latest apt history record mentions a librewolf package.
librewolf_in_apt_history() {
    [[ -f "$HISTORY_LOG" ]] || return 1
    python3 - "$HISTORY_LOG" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(errors="replace").strip()
if not text:
    raise SystemExit(1)
block = text.split("\n\n")[-1]
# Install/Upgrade/Remove/Purge lines list pkg:arch (version, ...)
pkg_line = re.compile(
    r"^(Install|Upgrade|Reinstall|Remove|Purge):\s*(.*)$",
    re.MULTILINE,
)
pkg_name = re.compile(r"(?:^|,\s*)([a-z0-9][a-z0-9+.-]*)(?::[a-z0-9]+)?\s*\(", re.I)
for match in pkg_line.finditer(block):
    for name in pkg_name.findall(match.group(2)):
        if name == "librewolf" or name.startswith("librewolf-"):
            raise SystemExit(0)
raise SystemExit(1)
PY
}

# Fallback for `dpkg -i` / recoveries where apt history may not list the pkg:
# librewolf's dpkg info or distribution policies were touched in this invoke.
librewolf_touched_recently() {
    local path now mtime
    now=$(date +%s)
    for path in \
        /var/lib/dpkg/info/librewolf.list \
        /usr/share/librewolf/distribution/policies.json \
        /usr/lib/librewolf/distribution/policies.json
    do
        [[ -e "$path" ]] || continue
        mtime=$(stat -c %Y "$path" 2>/dev/null || echo 0)
        # Post-Invoke runs at end of the transaction; allow a small skew window.
        if (( now - mtime <= 600 )); then
            return 0
        fi
    done
    return 1
}

librewolf_present || exit 0

if librewolf_in_apt_history || librewolf_touched_recently; then
    "$POLICY_SH" "$FRAGMENT" || true
fi
