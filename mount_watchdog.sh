#!/bin/bash
# Watchdog that ensures auto_smb is present and remounts /Users/example/Media if it stays down

PATH="/usr/sbin:/usr/bin:/bin:/sbin:/usr/local/sbin:/usr/local/bin"

MOUNTPOINT="/Users/example/Media"
COUNTER_FILE="/var/run/mount_watchdog.count"
THRESHOLD=3                  # consecutive misses before healing (~3 minutes at 60s interval)
LOGTAG="mount-watchdog"

AUTO_MASTER="/etc/auto_master"
AUTO_MASTER_BKP="/etc/auto_master.bkp"
AUTO_SMB_LINE="/-      auto_smb"

# --- Ensure auto_smb is present in /etc/auto_master (simple grep) ---
if ! grep -q "auto_smb" "$AUTO_MASTER"; then
  [ -f "$AUTO_MASTER_BKP" ] || cp "$AUTO_MASTER" "$AUTO_MASTER_BKP"
  printf "\n%s\n" "$AUTO_SMB_LINE" >> "$AUTO_MASTER"
  logger -t "$LOGTAG" "Added '$AUTO_SMB_LINE' to $AUTO_MASTER"
  /usr/sbin/automount -vc >/dev/null 2>&1 || true
fi

# --- Ensure mountpoint exists ---
[ -d "$MOUNTPOINT" ] || /bin/mkdir -p "$MOUNTPOINT"

# --- If already mounted, reset counter and exit ---
if /sbin/mount | /usr/bin/grep -q " on $MOUNTPOINT "; then
  echo 0 > "$COUNTER_FILE"
  exit 0
fi

# --- Not mounted: increment consecutive-fail counter ---
count=$(/bin/cat "$COUNTER_FILE" 2>/dev/null || echo 0)
# Validate counter is a number, reset if corrupted
if ! [[ "$count" =~ ^[0-9]+$ ]]; then
  logger -t "$LOGTAG" "Counter file corrupted, resetting to 0"
  count=0
fi
count=$((count + 1))
echo $count > "$COUNTER_FILE"

# Only heal after N consecutive misses
[ "$count" -lt "$THRESHOLD" ] && exit 0

/usr/bin/logger -t "$LOGTAG" "Missing for $count checks. Healing."

# Clear any stale state, reload maps, and trigger mount
/sbin/umount -f "$MOUNTPOINT" 2>/dev/null
/usr/sbin/automount -vc >/dev/null 2>&1
timeout 30 /bin/ls "$MOUNTPOINT" >/dev/null 2>&1 || logger -t "$LOGTAG" "Mount trigger timeout after 30s"

if /sbin/mount | /usr/bin/grep -q " on $MOUNTPOINT "; then
  /usr/bin/logger -t "$LOGTAG" "Remount successful."
  echo 0 > "$COUNTER_FILE"
else
  /usr/bin/logger -t "$LOGTAG" "Remount failed."
fi