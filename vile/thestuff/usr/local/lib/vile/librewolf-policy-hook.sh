#!/bin/bash
# apt Post-Invoke wrapper: only re-merge when LibreWolf is present.
set -euo pipefail

FRAGMENT="/usr/local/share/vile/librewolf-policies.json"
POLICY_SH="/usr/local/lib/vile/librewolf-policy.sh"

[[ -x "$POLICY_SH" ]] || exit 0
[[ -f "$FRAGMENT" ]] || exit 0

if [[ -x /usr/bin/librewolf ]] \
    || [[ -d /usr/lib/librewolf ]] \
    || [[ -d /usr/share/librewolf ]]; then
    "$POLICY_SH" "$FRAGMENT" || true
fi
