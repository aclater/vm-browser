# shellcheck shell=bash disable=SC2016  # the checks are bash -c scripts, expanded when they run
# SSH to the VM (#6): the desktop's ssh_config must never apply.

check "every ssh and scp in the script passes -F none" \
  bash -c '! grep -nE "(^|[(\"; ])(ssh|scp)( -q)? -" vm-browser.sh | grep -v -- "-F none"'
check "load_port's ssh command starts with -F none" \
  bash -c 'source ./vm-browser.sh; DIR=$T; KEYF=$T/k KH=$T/kh; echo 2299 > "$T/port"; load_port; [ "${SSH[0]} ${SSH[1]} ${SSH[2]}" = "ssh -F none" ]'
