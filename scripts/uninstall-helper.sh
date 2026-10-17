#!/bin/bash
# Removes the Noema Snitch helper, its pf rules and its group. Keeps saved rules.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"

LABEL="com.noema.snitch.helper"
launchctl bootout "system/$LABEL" 2>/dev/null
pfctl -a com.apple/noemasnitch -F all 2>/dev/null
rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/PrivilegedHelperTools/$LABEL" /var/run/com.noema.snitch.sock
dseditgroup -o delete _noemasnitch 2>/dev/null
echo "Helper removed. Saved rules remain in /Library/Application Support/NoemaSnitch."
