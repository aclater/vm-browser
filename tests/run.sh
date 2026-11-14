#!/bin/bash
# Unit tests for vm-browser.sh: the parts that need no VM (argument checks, the files it
# writes, its handling of what a VM or a download returns). Each tests/test_*.sh file is
# sourced in turn; each check runs in a subshell, which sources vm-browser.sh where it needs
# its functions. Run from anywhere: tests/run.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0 FAIL=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT   # scratch space for the checks
export T

# check NAME CMD...: passes when CMD succeeds. fails NAME CMD...: passes when CMD fails.
# A failing check prints CMD's output.
run_check() {
  local want=$1 name=$2; shift 2
  local out rc; out=$("$@" 2>&1); rc=$?
  if { [ "$want" = ok ] && [ $rc -eq 0 ]; } || { [ "$want" = fail ] && [ $rc -ne 0 ]; }; then
    PASS=$((PASS+1)); printf 'ok   %s\n' "$name"
  else
    FAIL=$((FAIL+1)); printf 'FAIL %s (exit %s)\n%s\n' "$name" "$rc" "$out" | sed '2,$s/^/     /'
  fi
}
check() { run_check ok "$@"; }
fails() { run_check fail "$@"; }

for t in tests/test_*.sh; do
  printf '\n# %s\n' "$t"
  # shellcheck source=/dev/null
  source "$t"
done
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
