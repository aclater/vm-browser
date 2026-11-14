# shellcheck shell=bash disable=SC2016  # the checks are bash -c scripts, expanded when they run
# Launchers (#1): what the VM reports about a package (.desktop Name, Exec, Icon,
# StartupWMClass) is hostile input. It must never become a command on the desktop.

# A fake desktop: HOME under $T, and stubs for virsh, ssh and waypipe that record their
# arguments, one per line, in $T/calls.
mkdir -p "$T/stubs"
for c in virsh ssh waypipe scp gtk-update-icon-cache; do
  printf '#!/bin/bash\nprintf "%%s\\n" "%s" "$@" "--" >> "$T/calls"\n[ "%s" != virsh ] || [ "$1" != domstate ] || echo running\n' "$c" "$c" > "$T/stubs/$c"
  chmod +x "$T/stubs/$c"
done
export PATH="$T/stubs:$PATH"
# ssh answers "no update running" to the launcher's check before it stops the VM (#9).
cat > "$T/stubs/ssh" <<'STUB'
#!/bin/bash
printf '%s\n' ssh "$@" -- >> "$T/calls"
case "${*: -1}" in *is-active*) exit "${UPDATE_RUNNING:-1}";; esac
STUB

# launcher_for EXE [NAME] [WM] [VM-NAME]: runs make_launcher with a stubbed VM that reports
# these values for package "testpkg", in a fresh HOME. Prints nothing; files land in $T/home.
launcher_for() {
  rm -rf "${T:?}/home" "${T:?}/calls"; mkdir -p "$T/home"
  HOME=$T/home bash -c '
    source ./vm-browser.sh
    NAME=${4:-testvm} KEYF=$T/key BKEYF=$T/bkey KH=$T/kh PORT=2299 R_EXE=$1 R_NAME=${2:-Test Browser} R_WM=${3:-}
    vmsh() { cat >/dev/null; printf "%s\n%s\n\n%s\n" "$R_NAME" "$R_EXE" "$R_WM"; }
    make_launcher testpkg' _ "$@"
}
export -f launcher_for
L='$T/home/.local/bin/vmb-testvm-testpkg'
D='$T/home/.local/share/applications/vmb-testvm-testpkg.desktop'

# The guest's shell parses the command line ssh sends: it must give back the same arguments.
check "the launcher runs the command in the VM with its arguments quoted (#7)" \
  bash -c "launcher_for /usr/bin/firefox && rm -f \$T/calls && $L 'https://example.test/?a=1&b=\$(id);c' \"two words\" && cmd=\$(grep '^/usr/bin/firefox' \$T/calls) && eval \"set -- \$cmd\" && [ \$# = 3 ] && [ \"\$2\" = 'https://example.test/?a=1&b=\$(id);c' ] && [ \"\$3\" = 'two words' ]"
check "the launcher logs in with the browser key, not the admin key (#7)" \
  bash -c "launcher_for /usr/bin/firefox && rm -f \$T/calls && $L && grep -qx \$T/bkey \$T/calls && ! grep -qx \$T/key \$T/calls && grep -qx StrictHostKeyChecking=yes \$T/calls"
for evil in '/usr/bin/firefox;touch${IFS}/tmp/pwned' '$(touch /tmp/pwned)' '`touch /tmp/pwned`' \
            '/usr/bin/a|sh' '/usr/bin/a&&id' 'firefox"' "firefox'" '../../bin/sh' 'fire fox' \
            '-A' '-oProxyCommand=id' '/usr/bin/-x' 'bin/-X' '.hidden/x' '/usr//bin/x'; do
  check "a start command with shell characters is refused: $(printf '%q' "$evil")" \
    bash -c '! out=$(launcher_for "$1" 2>&1) && grep -q "refusing the start command" <<< "$out"' _ "$evil"
  check "  ...and no launcher is written" bash -c "[ ! -e $L ]"
done
# The VM answers one value per line, so a newline in a value shifts the rest: the shifted
# values are still checked.
check "an extra line from the VM shifts the values, and the shifted command is refused" \
  bash -c "! out=\$(launcher_for /usr/bin/firefox \$'Evil\nExec=/bin/sh -c pwned' 2>&1) && grep -q 'refusing the start command' <<< \"\$out\" && [ ! -e $L ]"
check "a name with control characters (escape sequences, CR, tab) is cleaned in the menu entry" \
  bash -c "launcher_for /usr/bin/firefox \$'Evil\033]0;x\a\r\tName' && grep -qx 'Name=Evil]0;xName (testvm)' $D && [ \$(wc -l < $D) = 9 ]"
check "a window class with shell characters falls back to the command's name" \
  bash -c "launcher_for /usr/bin/firefox Firefox 'x;y' && grep -qx StartupWMClass=firefox $D"
check "the menu entry's Exec is the launcher, quoted for the .desktop format" \
  bash -c "launcher_for /usr/bin/firefox && grep -qx \"Exec=\\\"\$T/home/.local/bin/vmb-testvm-testpkg\\\"\" $D"
check "desktop_quote escapes quotes, backslashes, backticks and dollars" \
  bash -c 'source ./vm-browser.sh; [ "$(desktop_quote "/a b/\"\\\`\$x")" = "\"/a b/\\\"\\\\\\\`\\\$x\"" ]'
check "the launcher's VM name is a quoted value, not code" \
  bash -c 'launcher_for /usr/bin/firefox "" "" "a b'"'"'\$(id)" && bash -n "$T/home/.local/bin/vmb-a b'"'"'\$(id)-testpkg" && rm -f "$T/calls" && "$T/home/.local/bin/vmb-a b'"'"'\$(id)-testpkg" && grep -qx "a b'"'"'\$(id)" "$T/calls"'
fails "a package name with shell characters is refused" \
  bash -c 'source ./vm-browser.sh; NAME=t; make_launcher "x;id"'
check "clean_text drops control characters and newlines" \
  bash -c 'source ./vm-browser.sh; [ "$(printf "a\033[2Jb\nc" | clean_text)" = "a[2Jbc" ]'
check "clean_text drops C1 controls (8-bit CSI) but keeps other UTF-8 text" \
  bash -c 'source ./vm-browser.sh; [ "$(printf "a\xc2\x9b2Jb\xc3\xa9" | clean_text)" = "$(printf "a2Jb\xc3\xa9")" ]'
check "plain command paths are accepted" \
  bash -c 'source ./vm-browser.sh; for p in /usr/bin/firefox /opt/google/chrome/google-chrome brave-browser /usr/lib64/c++/x_y.sh; do safe_path "$p" || exit 1; done'

# waypipe --secctx (#3). Whether the compositor offers wp_security_context_v1 is probed on the
# desktop with a local "waypipe client". The stub fails that probe like waypipe on GNOME when
# NOSECCTX is set; otherwise its probe stays up with its socket, like waypipe on Sway.
cat > "$T/stubs/waypipe" <<'STUB'
#!/bin/bash
printf '%s\n' waypipe "$@" -- >> "$T/calls"
if [ "${*: -1}" = client ]; then
  [ -z "${NOSECCTX:-}" ] || { echo 'Error: "src/secctx.rs:56: Compositor did not provide wp_security_context_manager_v1 global"' >&2; exit 1; }
  while [ $# -gt 0 ]; do [ "$1" = -s ] && touch "$2"; shift; done; echo $$ > "$T/probe-pid"; exec sleep 30
fi
[ -z "${VM_SAYS:-}" ] || echo "$VM_SAYS" >&2   # what the VM prints on the ssh connection
exit "${BROWSER_EXIT:-0}"
STUB
# runs: the waypipe calls that ran the browser (not the probe), one line each.
runs() { awk '/^waypipe$/{c=""; r=1; next} /^--$/{if(r) print c; r=0; next} {c=c" "$0}' "$T/calls" | grep -v ' client$'; }
export -f runs
check "the launcher asks for a security context named after the VM where the compositor offers one" \
  bash -c "launcher_for /usr/bin/firefox && rm -f \$T/calls && $L && [ \$(runs | wc -l) = 1 ] && runs | grep -q -- ' --secctx vm-browser.testvm '"
check "without the protocol (GNOME) the launcher runs waypipe once, without --secctx" \
  bash -c "launcher_for /usr/bin/firefox && rm -f \$T/calls && NOSECCTX=1 $L && [ \$(runs | wc -l) = 1 ] && ! runs | grep -q -- --secctx"
check "a VM that prints waypipe's no-secctx error and fails gets no second run without --secctx" \
  bash -c "launcher_for /usr/bin/firefox && rm -f \$T/calls && ! VM_SAYS='Error: \"src/secctx.rs:56: Compositor did not provide wp_security_context_manager_v1 global\"' BROWSER_EXIT=1 $L 2>/dev/null && [ \$(runs | wc -l) = 1 ] && runs | grep -q -- --secctx"
check "a browser that exits with an error is not started a second time" \
  bash -c "launcher_for /usr/bin/firefox && rm -f \$T/calls && ! BROWSER_EXIT=3 $L && [ \$(runs | wc -l) = 1 ]"
check "the probe's local waypipe client is stopped" \
  bash -c "launcher_for /usr/bin/firefox && rm -f \$T/calls \$T/probe-pid && $L && [ -s \$T/probe-pid ] && ! kill -0 \$(cat \$T/probe-pid) 2>/dev/null"

# Stopping the VM when the last launcher closes (#9). The stub waypipe can keep a "window"
# open for BROWSER_SECONDS.
cat > "$T/stubs/waypipe" <<'STUB'
#!/bin/bash
printf '%s\n' waypipe "$@" -- >> "$T/calls"
[ "${*: -1}" != client ] || exit 1   # the --secctx probe: a compositor without it
sleep "${BROWSER_SECONDS:-0}"
STUB
check "closing the only browser shuts the VM down" \
  bash -c "launcher_for /usr/bin/firefox && rm -f \$T/calls && XDG_RUNTIME_DIR=\$T/run1 $L && grep -A1 -x virsh \$T/calls | grep -qx shutdown"
check "closing one of two browsers leaves the VM running; closing the second stops it" \
  bash -c "launcher_for /usr/bin/firefox && rm -f \$T/calls && export XDG_RUNTIME_DIR=\$T/run2 && (BROWSER_SECONDS=3 $L &) && sleep 1 && $L && ! grep -qx shutdown \$T/calls && sleep 4 && [ \$(grep -cx shutdown \$T/calls) = 1 ]"
check "a launcher that died doesn't keep the VM running" \
  bash -c "launcher_for /usr/bin/firefox && rm -f \$T/calls && mkdir -p -m 700 \$T/run3/vm-browser-testvm && touch \$T/run3/vm-browser-testvm/session.999999 && XDG_RUNTIME_DIR=\$T/run3 $L && grep -qx shutdown \$T/calls"
check "VMB_KEEP_RUNNING=1 leaves the VM running" \
  bash -c "launcher_for /usr/bin/firefox && rm -f \$T/calls && XDG_RUNTIME_DIR=\$T/run4 VMB_KEEP_RUNNING=1 $L && ! grep -qx shutdown \$T/calls"
check "a running update (oneshot: activating) keeps the VM up until it finishes" \
  bash -c "launcher_for /usr/bin/firefox && grep -q 'activating|active' \$T/home/.local/bin/vmb-testvm-testpkg"
