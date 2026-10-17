#!/bin/bash
# Installs the Noema Snitch helper as a root LaunchDaemon. Asks for the administrator password.
# Works from the project (after scripts/build-app.sh) and from inside the app bundle,
# where the app runs it via "Install Helper…".
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
HERE="$(cd "$(dirname "$0")" && pwd)"

LABEL="com.noema.snitch.helper"
if [ -f "$HERE/NoemaHelper" ]; then
    SRC="$HERE/NoemaHelper"
else
    SRC="$HERE/../build/Noema Snitch.app/Contents/Resources/NoemaHelper"
fi
DST="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
GROUP="_noemasnitch"

[ -f "$SRC" ] || { echo "Build first: ./scripts/build-app.sh"; exit 1; }

# Dedicated group: the helper's own sockets carry it so pf does not redirect them.
if ! dscl . -read "/Groups/$GROUP" >/dev/null 2>&1; then
    for gid in $(seq 450 499); do
        if [ -z "$(dscl . -search /Groups PrimaryGroupID "$gid" 2>/dev/null)" ]; then
            dseditgroup -o create -i "$gid" -r "Noema Snitch helper" "$GROUP"
            echo "Created group $GROUP ($gid)"
            break
        fi
    done
fi

launchctl bootout "system/$LABEL" 2>/dev/null || true
# bootout returns before the old instance is gone; bootstrapping too early fails with error 5.
for _ in $(seq 1 50); do
    launchctl print "system/$LABEL" >/dev/null 2>&1 || break
    sleep 0.2
done

install -d -m 755 -o root -g wheel /Library/PrivilegedHelperTools
install -m 755 -o root -g wheel "$SRC" "$DST"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DST</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/noemasnitch.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/noemasnitch.log</string>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

for attempt in 1 2 3 4 5; do
    launchctl bootstrap system "$PLIST" 2>/dev/null && break
    [ "$attempt" -eq 5 ] && { launchctl bootstrap system "$PLIST"; exit 1; }
    sleep 1
done
echo "Helper installed and started. Log: /var/log/noemasnitch.log"
echo "If the network ever stops working: sudo ./scripts/emergency-off.sh"
