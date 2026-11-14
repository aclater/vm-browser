# shellcheck shell=bash disable=SC2016  # the checks are bash -c scripts, expanded when they run
# Disposable VMs (#9): a VM with a base.qcow2 runs each session on a new overlay, which its
# launcher replaces before the VM starts and after it stops. Runs of vm-browser.sh are
# maintenance: they need the VM shut off and hold the launchers off.
# Uses launcher_for and the stubs from test_launcher.sh (sourced earlier). Here virsh keeps a VM state in
# $T/vstate, and qemu-img records its calls and makes the overlay file.
mkdir -p "$T/dstubs"
cat > "$T/dstubs/virsh" <<'STUB'
#!/bin/bash
printf '%s\n' virsh "$@" -- >> "$T/calls"
case "$1" in
  domstate) cat "$T/vstate" 2>/dev/null || echo running;;
  start) echo running > "$T/vstate";;
  shutdown) [ -n "${IGNORE_SHUTDOWN:-}" ] || echo "shut off" > "$T/vstate";;
  destroy) echo "shut off" > "$T/vstate";;
esac
STUB
cat > "$T/dstubs/qemu-img" <<'STUB'
#!/bin/bash
printf '%s\n' qemu-img "$@" -- >> "$T/calls"
[ -z "${QEMU_FAIL:-}" ] || exit 1
[ "$1" != create ] || : > "${*: -1}"
STUB
chmod +x "$T/dstubs/virsh" "$T/dstubs/qemu-img"
# dl STATE [VAR=VALUE...]: a launcher for a disposable VM in state STATE, then run it.
dl() {
  launcher_for /usr/bin/firefox && touch "$T/home/base.qcow2" && echo "$1" > "$T/vstate" && shift
  rm -f "$T/calls"; env PATH="$T/dstubs:$PATH" XDG_RUNTIME_DIR="$T/drun" "$@" "$T/home/.local/bin/vmb-testvm-testpkg"
}
# line N PATTERN: the line number of the first call line matching PATTERN (0 if none).
line() { grep -nx -- "$1" "$T/calls" | head -1 | cut -d: -f1 | grep . || echo 0; }
export -f dl line

check "a disposable VM starts on a new overlay on its base" \
  bash -c 'dl "shut off" && grep -qx -- "$T/home/base.qcow2" "$T/calls" && c=$(line create) && s=$(line start) && [ "$c" -gt 0 ] && [ "$s" -gt "$c" ]'
check "a persistent VM's launcher makes no overlay" \
  bash -c 'launcher_for /usr/bin/firefox && echo "shut off" > "$T/vstate" && rm -f "$T/calls" && PATH="$T/dstubs:$PATH" XDG_RUNTIME_DIR="$T/drun" "$T/home/.local/bin/vmb-testvm-testpkg" && ! grep -qx qemu-img "$T/calls" && grep -qx start "$T/calls"'
check "a VM that is already running gets no new overlay at the start" \
  bash -c 'dl running && [ "$(line create)" -gt "$(line shutdown)" ] && [ "$(grep -cx create "$T/calls")" = 1 ]'
check "after the last window closes the overlay is replaced, without waiting for updates" \
  bash -c 'dl running UPDATE_RUNNING=0 && s=$(line shutdown) && c=$(line create) && [ "$s" -gt 0 ] && [ "$c" -gt "$s" ] && ! grep -q dnf5-automatic "$T/calls"'
check "a guest that ignores the shutdown is switched off, then its overlay replaced" \
  bash -c 'dl running IGNORE_SHUTDOWN=1 2>/dev/null && d=$(line destroy) && c=$(line create) && [ "$d" -gt 0 ] && [ "$c" -gt "$d" ]'
check "with another launcher open, the overlay is kept" \
  bash -c 'mkdir -p -m 700 "$T/drun/vm-browser-testvm" && (sleep 6 & echo $! > "$T/other") && touch "$T/drun/vm-browser-testvm/session.$(cat "$T/other")" && dl running && ! grep -qx create "$T/calls" && ! grep -qx shutdown "$T/calls"; r=$?; rm -f "$T"/drun/vm-browser-testvm/session.*; exit $r'
check "the launcher refuses to start while vm-browser.sh updates the VM" \
  bash -c 'mkdir -p -m 700 "$T/drun/vm-browser-testvm" && echo $$ > "$T/drun/vm-browser-testvm/maintenance" && ! dl "shut off" 2>/dev/null && ! grep -qx start "$T/calls" && ! grep -qx waypipe "$T/calls"; r=$?; rm -f "$T/drun/vm-browser-testvm/maintenance"; exit $r'
check "...but a maintenance file left by a run that died is ignored" \
  bash -c 'mkdir -p -m 700 "$T/drun/vm-browser-testvm" && echo 999999 > "$T/drun/vm-browser-testvm/maintenance" && dl "shut off" && grep -qx start "$T/calls"; r=$?; rm -f "$T/drun/vm-browser-testvm/maintenance"; exit $r'
check "without a new overlay the VM isn't started" \
  bash -c '! dl "shut off" QEMU_FAIL=1 2>/dev/null && ! grep -qx start "$T/calls" && ! grep -qx waypipe "$T/calls"'

# Maintenance in vm-browser.sh. m SCRIPT: runs SCRIPT with the script's functions, a VM folder
# in $T/m, and the stubs.
m() {
  rm -rf "$T/m" "$T/calls"; mkdir -p "$T/m"
  PATH="$T/dstubs:$PATH" XDG_RUNTIME_DIR="$T/mrun" bash -c 'source ./vm-browser.sh; NAME=testvm DIR=$T/m; vm() { return 1; }; '"$1"
}
export -f m
check "maintenance refuses while the VM is running" \
  bash -c 'echo running > "$T/vstate"; ! m "WANT_DISPOSABLE=1; begin_maintenance" 2>/dev/null'
check "maintenance refuses while a browser is open" \
  bash -c 'echo "shut off" > "$T/vstate"; mkdir -p -m 700 "$T/mrun/vm-browser-testvm" && touch "$T/mrun/vm-browser-testvm/session.$$" && ! m "WANT_DISPOSABLE=1; begin_maintenance" 2>/dev/null; r=$?; rm -f "$T"/mrun/vm-browser-testvm/session.*; exit $r'
check "a persistent VM's run needs no maintenance (it may be running)" \
  bash -c 'echo running > "$T/vstate"; m "WANT_DISPOSABLE=0; begin_maintenance; [ -z \"\$MAINT\" ]"'
check "maintenance of a disposable VM boots a new overlay and holds the launchers off" \
  bash -c 'echo "shut off" > "$T/vstate"; m "touch \$DIR/base.qcow2; WANT_DISPOSABLE=1; begin_maintenance; [ \"\$(cat \$RUN/maintenance)\" = \$\$ ] && [ -e \$DIR/disk.qcow2 ]; r=\$?; trap - EXIT; exit \$r" && grep -qx create "$T/calls"'
check "a run that fails discards its changes and lets the launchers in again" \
  bash -c 'echo "shut off" > "$T/vstate"; m "touch \$DIR/base.qcow2; WANT_DISPOSABLE=1; begin_maintenance; false" ; [ ! -e "$T/mrun/vm-browser-testvm/maintenance" ] && [ "$(line destroy)" -gt 0 ] && [ "$(grep -cx create "$T/calls")" = 2 ]'
check "the end of maintenance writes the run's changes into the base, read-only, on a new overlay" \
  bash -c 'echo "shut off" > "$T/vstate"; m "touch \$DIR/base.qcow2; WANT_DISPOSABLE=1; begin_maintenance; echo running > \$T/vstate; end_maintenance; [ ! -e \$RUN/maintenance ] && [ \"\$(stat -c %a \$DIR/base.qcow2)\" = 400 ]" && c=$(line commit) && [ "$c" -gt "$(line shutdown)" ] && [ "$(grep -n -x create "$T/calls" | tail -1 | cut -d: -f1)" -gt "$c" ]'
check "a persistent VM made disposable: its disk becomes the base" \
  bash -c 'echo "shut off" > "$T/vstate"; m "echo disk > \$DIR/disk.qcow2; WANT_DISPOSABLE=1; begin_maintenance; echo running > \$T/vstate; end_maintenance; [ \"\$(cat \$DIR/base.qcow2)\" = disk ] && [ ! -s \$DIR/disk.qcow2 ]" && ! grep -qx commit "$T/calls"'
check "--persistent: the base becomes the VM's disk again" \
  bash -c 'echo "shut off" > "$T/vstate"; m "echo base > \$DIR/base.qcow2; chmod 400 \$DIR/base.qcow2; : > \$DIR/disk.qcow2; WANT_DISPOSABLE=0; begin_maintenance; [ ! -e \$DIR/base.qcow2 ] && [ \"\$(cat \$DIR/disk.qcow2)\" = base ] && [ -z \"\$MAINT\" ]"'
check "a shutdown that never comes discards the run's changes" \
  bash -c 'echo "shut off" > "$T/vstate"; m "touch \$DIR/base.qcow2; WANT_DISPOSABLE=1; begin_maintenance; echo running > \$T/vstate; sleep() { :; }; IGNORE_SHUTDOWN=1 end_maintenance" 2>/dev/null; ! grep -qx commit "$T/calls" && [ "$(line destroy)" -gt 0 ]'
check "--update and --disposable need no browser" \
  bash -c 'source ./vm-browser.sh; parse_args --update && parse_args --disposable && parse_args --persistent --name x'
rm -f "$T/vstate"
