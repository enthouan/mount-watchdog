#!/bin/bash
set -euo pipefail

# Config
LABEL="com.antoinemenard.mount-watchdog"
MOUNTPOINT="/Users/example/Media"
SCRIPT="/usr/local/sbin/mount_watchdog.sh"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
LOGTAG="mount-watchdog"
INTERVAL=60          # seconds between checks
THRESHOLD=3          # consecutive misses before healing

need_root() { [ "$EUID" -eq 0 ] || { echo "Please run with sudo"; exit 1; }; }

uninstall() {
  launchctl bootout system/"$LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$SCRIPT"
  echo "Removed $LABEL"
  exit 0
}

status() {
  echo "launchd job:"
  launchctl print system/"$LABEL" 2>/dev/null | egrep 'state|pid|last exit' || echo "not loaded"
  echo
  echo "Recent logs:"
  log show --predicate "eventMessage CONTAINS \"$LOGTAG\"" --last 15m || true
  echo
  mount | grep " $MOUNTPOINT " || echo "$MOUNTPOINT is not mounted"
  exit 0
}

need_root
case "${1:-install}" in
  uninstall) uninstall ;;
  status) status ;;
esac

# Ensure dirs
install -d -m 755 /usr/local/sbin
chown root:wheel /usr/local/sbin

# Copy watchdog script
[ -f mount_watchdog.sh ] || { echo "mount_watchdog.sh not found in current directory"; exit 1; }
cp mount_watchdog.sh "$SCRIPT" || { echo "Failed to copy mount_watchdog.sh"; exit 1; }

chown root:wheel "$SCRIPT"
chmod 755 "$SCRIPT"

# Validate copied script
head -1 "$SCRIPT" | grep -q "#!/bin/bash" || { echo "Invalid script copied"; exit 1; }

# Write LaunchDaemon
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SCRIPT</string>
  </array>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/var/log/$LOGTAG.out</string>
  <key>StandardErrorPath</key><string>/var/log/$LOGTAG.err</string>
</dict>
</plist>
EOF

chown root:wheel "$PLIST"
chmod 644 "$PLIST"

# Load and start
launchctl bootout system/"$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
launchctl start "$LABEL"

echo "Installed and started $LABEL"
echo
launchctl print system/"$LABEL" | egrep 'state|pid|last exit' || true
echo
echo "Tip: sudo bash $(basename "$0") status  to view logs and state"
echo "Tip: sudo bash $(basename "$0") uninstall  to remove"