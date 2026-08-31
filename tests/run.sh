#!/bin/bash
set -e

TEST_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH='' cd -- "$TEST_DIR/.." && pwd)

printf '==> syntax\n'
while IFS= read -r shell_file; do
  /bin/bash -n "$shell_file"
done <<EOF
$(/usr/bin/find "$PROJECT_DIR" -type f -name '*.sh' -print | /usr/bin/sort)
EOF

static_tmp=$(mktemp -d "${TMPDIR:-/tmp}/mountwatchdog-static.XXXXXX")
cleanup_static() {
  case "$static_tmp" in
    "${TMPDIR:-/tmp}"/mountwatchdog-static.*) /bin/rm -R "$static_tmp" ;;
    *) printf 'Refusing unsafe static-check cleanup: %s\n' "$static_tmp" >&2 ;;
  esac
}
trap cleanup_static EXIT HUP INT TERM

/usr/bin/sed 's/@INTERVAL_SECONDS@/60/g' \
  "$PROJECT_DIR/packaging/com.antoinemenard.mount-watchdog.plist.in" \
  >"$static_tmp/com.antoinemenard.mount-watchdog.plist"
if [ -x /usr/bin/plutil ]; then
  /usr/bin/plutil -lint "$static_tmp/com.antoinemenard.mount-watchdog.plist"
fi

test_files="
$TEST_DIR/test_common.sh
$TEST_DIR/test_runtime.sh
$TEST_DIR/test_installer.sh
"

for test_file in $test_files; do
  [ -f "$test_file" ] || {
    printf 'Required test file is missing: %s\n' "${test_file#"$PROJECT_DIR"/}" >&2
    exit 1
  }
  printf '\n==> %s\n' "${test_file#"$PROJECT_DIR"/}"
  /bin/bash "$test_file"
done

cleanup_static
trap - EXIT HUP INT TERM
