# shellcheck shell=bash disable=SC2016  # the checks are bash -c scripts, expanded when they run
# Argument parsing (parse_args): no VM, no host tools needed.

check "--help exits 0" ./vm-browser.sh --help
fails "an unknown argument is refused" ./vm-browser.sh --bogus
fails "no browser and no --rpm is refused" ./vm-browser.sh --os fedora
fails "an unknown --os is refused" ./vm-browser.sh --os debian firefox
check "sourcing the script runs nothing" bash -c 'out=$(source ./vm-browser.sh 2>&1) && [ -z "$out" ]'
check "Fedora defaults: version 44, name fedora44-browsers" \
  bash -c 'source ./vm-browser.sh; parse_args firefox; [ "$VER" = 44 ] && [ "$NAME" = fedora44-browsers ]'
check "RHEL defaults: version 10, name rhel10-browsers" \
  bash -c 'source ./vm-browser.sh; parse_args --os rhel firefox; [ "$VER" = 10 ] && [ "$NAME" = rhel10-browsers ]'
check "browsers are collected in order" \
  bash -c 'source ./vm-browser.sh; parse_args firefox chrome; [ "${BROWSERS[*]}" = "firefox chrome" ]'
