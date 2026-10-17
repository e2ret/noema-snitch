#!/bin/bash
# Restores normal networking immediately: stops the helper and drops its pf redirect.
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
launchctl bootout system/com.noema.snitch.helper 2>/dev/null
pfctl -a com.apple/noemasnitch -F all 2>/dev/null
echo "Noema Snitch filtering is off. Reinstall with scripts/install-helper.sh."
