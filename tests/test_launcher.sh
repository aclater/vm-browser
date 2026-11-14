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
            '/usr/bin/a|sh' '/usr/bin/a&&id' 'firefox"' "firefox'" '../../bin/sh' 'fire fox'; do
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

# waypipe --secctx (#3). The stub waypipe fails like waypipe on GNOME when NOSECCTX is set.
cat > "$T/stubs/waypipe" <<'STUB'
#!/bin/bash
printf '%s\n' waypipe "$@" -- >> "$T/calls"
if [ "$1" = --secctx ] && [ -n "${NOSECCTX:-}" ]; then
  echo 'Error: "src/secctx.rs:56: Compositor did not provide wp_security_context_manager_v1 global"' >&2; exit 1
fi
exit "${BROWSER_EXIT:-0}"
STUB
check "the launcher asks for a security context named after the VM" \
  bash -c "launcher_for /usr/bin/firefox && rm -f \$T/calls && $L && [ \$(grep -cx waypipe \$T/calls) = 1 ] && grep -A1 -x -- --secctx \$T/calls | grep -qx vm-browser.testvm"
check "without the protocol (GNOME) it runs waypipe again without --secctx" \
  bash -c "launcher_for /usr/bin/firefox && rm -f \$T/calls && NOSECCTX=1 $L 2>/dev/null && [ \$(grep -cx waypipe \$T/calls) = 2 ] && [ \$(grep -cx -- --secctx \$T/calls) = 1 ]"
check "a browser that exits with an error is not started a second time" \
  bash -c "launcher_for /usr/bin/firefox && rm -f \$T/calls && ! BROWSER_EXIT=3 $L && [ \$(grep -cx waypipe \$T/calls) = 1 ]"
