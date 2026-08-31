#!/bin/bash

TESTS_RUN=0
TESTS_FAILED=0

test_fail() {
  printf 'not ok %s - %s\n' "$TESTS_RUN" "$*"
  TESTS_FAILED=$((TESTS_FAILED + 1))
  return 1
}

assert_eq() {
  assert_expected=$1
  assert_actual=$2
  assert_message=${3:-values differ}
  [ "$assert_expected" = "$assert_actual" ] || {
    printf '  expected: %s\n  actual:   %s\n' "$assert_expected" "$assert_actual" >&2
    test_fail "$assert_message"
  }
}

assert_file_absent() {
  [ ! -e "$1" ] || test_fail "unexpected file exists: $1"
}

run_test() {
  TESTS_RUN=$((TESTS_RUN + 1))
  test_name=$1
  shift
  if ("$@"); then
    printf 'ok %s - %s\n' "$TESTS_RUN" "$test_name"
  else
    printf 'not ok %s - %s\n' "$TESTS_RUN" "$test_name"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

finish_tests() {
  printf '1..%s\n' "$TESTS_RUN"
  [ "$TESTS_FAILED" -eq 0 ]
}
