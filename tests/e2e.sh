#!/bin/bash
# End-to-end test: builds a Fedora VM with vm-browser.sh, then checks the VM, the browser and
# the launcher. Needs KVM and the host packages from the README, and runs as a normal user
# (libvirt user session). CI runs it in a Fedora container (.github/workflows/e2e.yml);
# locally: tests/e2e.sh [extra vm-browser.sh options]. It removes its VM at the end.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=${E2E_NAME:-vmb-e2e-$$}
export LIBVIRT_DEFAULT_URI=qemu:///session
D="$HOME/.local/share/vm-browser/$NAME"
sway_pid=""
cleanup() {
  [ -z "$sway_pid" ] || kill "$sway_pid" 2>/dev/null || true
  # A RHEL VM is unregistered first, so it doesn't stay listed in the Red Hat account.
  if [ -f "$D/id_ed25519" ] && [ -f "$D/port" ]; then
    ssh -F none -i "$D/id_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile="$D/known_hosts" -o ConnectTimeout=5 -p "$(cat "$D/port")" admin@127.0.0.1 \
      'command -v subscription-manager >/dev/null && sudo subscription-manager unregister' >/dev/null 2>&1 || true
  fi
  virsh destroy "$NAME" >/dev/null 2>&1 || true
  virsh undefine "$NAME" --remove-all-storage >/dev/null 2>&1 || true
  rm -rf "$D" "$HOME/.local/bin/vmb-$NAME-"* "$HOME/.local/share/applications/vmb-$NAME-"*.desktop \
    "$HOME"/.local/share/icons/hicolor/*/apps/"vmb-$NAME-"*
}
[ -n "${E2E_KEEP:-}" ] || trap cleanup EXIT
fail() { echo "E2E FAIL: $*" >&2; exit 1; }
pass() { echo "E2E ok: $*"; }

# #6: a hostile ~/.ssh/config must not apply to the script's ssh or the launcher's. Only with
# E2E_HOSTILE_SSH_CONFIG=1 and a throwaway account (CI): ssh reads the passwd home, not $HOME.
if [ -n "${E2E_HOSTILE_SSH_CONFIG:-}" ]; then
  [ ! -e ~/.ssh/config ] || fail "refusing to replace an existing ~/.ssh/config"
  install -d -m 700 ~/.ssh
  printf 'Host *\n  ForwardAgent yes\n  ForwardX11 yes\n  RemoteCommand echo hijacked\n' > ~/.ssh/config
  eval "$(ssh-agent -s)" >/dev/null
fi

./vm-browser.sh --name "$NAME" --memory 3 --cpus 2 "$@" firefox
L="$HOME/.local/bin/vmb-$NAME-firefox"
[ -x "$L" ] || fail "no launcher at $L"
grep -q '^Exec=' "$HOME/.local/share/applications/vmb-$NAME-firefox.desktop" || fail "no desktop entry"
pass "launcher and desktop entry written"

# The launcher's own ssh command, as the browser user: its value line and its SSH= line.
SSH=()
eval "$(grep -E '^(VM|SSH)=' "$L")"
[ "$("${SSH[@]}" whoami)" = browser ] || fail "launcher does not log in as browser"
"${SSH[@]}" 'sudo -n true' 2>/dev/null && fail "browser user has sudo"
pass "launcher logs in as the unprivileged browser user"
"${SSH[@]}" 'firefox --version' | grep -q 'Mozilla Firefox' || fail "firefox does not run"
pass "firefox runs: $("${SSH[@]}" 'firefox --version')"
grep -q -- '-F none' "$L" || fail "launcher ssh reads the desktop's ssh_config"
if [ -n "${E2E_HOSTILE_SSH_CONFIG:-}" ]; then
  # shellcheck disable=SC2016  # expanded by the guest's shell
  [ -z "$("${SSH[@]}" 'echo "${SSH_AUTH_SOCK:-}${DISPLAY:-}"')" ] || fail "agent or X11 forwarded to the guest"
  pass "a hostile ~/.ssh/config (agent and X11 forwarding, RemoteCommand) is ignored"
fi

# #3: open the browser through the launcher on a headless Sway, which supports
# wp_security_context_v1, and check that Sway sees its window with the VM's security context.
# CI only (E2E_SWAY=1; needs sway, swaymsg and an XDG_RUNTIME_DIR of our own).
if [ -n "${E2E_SWAY:-}" ]; then
  export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman
  printf 'output HEADLESS-1 resolution 1280x800\n' > "$XDG_RUNTIME_DIR/sway.conf"
  sway -c "$XDG_RUNTIME_DIR/sway.conf" > "$XDG_RUNTIME_DIR/sway.log" 2>&1 & sway_pid=$!
  for _ in $(seq 1 50); do compgen -G "$XDG_RUNTIME_DIR/sway-ipc.*" >/dev/null && break; sleep 0.2; done
  WAYLAND_DISPLAY=$(basename "$(compgen -G "$XDG_RUNTIME_DIR/wayland-[0-9]" | head -1)")
  SWAYSOCK=$(compgen -G "$XDG_RUNTIME_DIR/sway-ipc.*" | head -1); export WAYLAND_DISPLAY SWAYSOCK
  "$L" about:blank > "$XDG_RUNTIME_DIR/launcher.log" 2>&1 & launcher_pid=$!
  found=""
  for _ in $(seq 1 90); do
    if swaymsg -t get_tree 2>/dev/null | grep -q "\"sandbox_app_id\": \"vm-browser.$NAME\""; then found=1; break; fi
    sleep 2
  done
  swaymsg -t get_tree 2>/dev/null | grep -E '"(app_id|sandbox_engine|sandbox_app_id)"' | sort -u || true
  kill "$launcher_pid" 2>/dev/null || true   # Sway keeps running for the launches below
  [ -n "$found" ] || { tail -20 "$XDG_RUNTIME_DIR/launcher.log" "$XDG_RUNTIME_DIR/sway.log" >&2; fail "no window with the VM's security context"; }
  pass "the browser's window reaches the compositor through waypipe, with the security context vm-browser.$NAME"
fi

# #2: a service on the desktop's loopback must be unreachable from the guest (passt maps the
# gateway address to it), while DNS and the internet work. Control: with the guard removed the
# same service is reachable, so the check means something.
LPORT=$((20000 + RANDOM % 20000))
python3 -m http.server --bind 127.0.0.1 "$LPORT" >/dev/null 2>&1 & http_pid=$!
sleep 1
ASSH=(ssh -F none -i "$D/id_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$D/known_hosts" -p "$(cat "$D/port")" admin@127.0.0.1)
GW=$("${ASSH[@]}" "ip -4 route show default | awk '{print \$3; exit}'")
probe() { "${SSH[@]}" "timeout 5 bash -c 'exec 3<>/dev/tcp/$1/$2' 2>/dev/null && echo open || echo closed"; }
[ "$(probe "$GW" "$LPORT")" = closed ] || fail "the guest reaches the desktop's loopback ($GW:$LPORT)"
"${ASSH[@]}" 'sudo nft delete table inet vm_browser'
reached=$(probe "$GW" "$LPORT")
"${ASSH[@]}" 'sudo systemctl restart vm-browser-netguard'
[ "$reached" = open ] || fail "control failed: without the guard the desktop's loopback wasn't reachable either"
[ "$(probe "$GW" "$LPORT")" = closed ] || fail "the guard did not come back"
kill "$http_pid" 2>/dev/null || true
"${SSH[@]}" 'curl -sSf -o /dev/null https://fedoraproject.org/' || fail "the browser account can't reach the internet"
pass "the desktop's loopback is blocked (open without the guard), the internet works"
if [ -n "${E2E_LAN_TARGET:-}" ]; then   # host:port of a LAN service the desktop itself can reach
  [ "$(probe "${E2E_LAN_TARGET%:*}" "${E2E_LAN_TARGET#*:}")" = closed ] || fail "the guest reaches the LAN ($E2E_LAN_TARGET)"
  pass "the LAN ($E2E_LAN_TARGET) is blocked"
fi

# #7: the VM's host key is pinned, and the admin and browser accounts have separate keys.
A=(ssh -F none -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$D/known_hosts" -p "$(cat "$D/port")")
{ [ "$(wc -l < "$D/known_hosts")" = 1 ] && grep -q ' ssh-ed25519 ' "$D/known_hosts"; } || fail "known_hosts is not one pinned ed25519 key"
"${A[@]}" -i "$D/id_ed25519" admin@127.0.0.1 true || fail "admin key refused"
"${A[@]}" -i "$D/id_ed25519" browser@127.0.0.1 true 2>/dev/null && fail "the admin key opens the browser account"
"${A[@]}" -i "$D/browser_ed25519" admin@127.0.0.1 true 2>/dev/null && fail "the browser key opens the admin account"
pass "host key pinned; admin and browser keys are separate"
if [ -n "${E2E_RHSM:-}" ]; then   # RHEL: the activation key must not be left anywhere in the VM
  # shellcheck disable=SC2016  # expanded by the guest's shell; the key comes on stdin
  left=$(sed -n 's/^key=//p' "$E2E_RHSM" | "${A[@]}" -i "$D/id_ed25519" admin@127.0.0.1 \
    'sudo bash -c '"'"'k=$(cat); find / -xdev -type f -size -64M -print0 2>/dev/null | xargs -0 grep -lsF -- "$k"'"'"'') || true
  [ -z "$left" ] || fail "the activation key is still in the VM: $left"
  pass "the activation key is nowhere in the VM's file system"
fi

# #1: a package whose .desktop Exec carries shell code must not get a launcher. Needs rpmbuild.
if command -v rpmbuild >/dev/null; then
  R=$(mktemp -d)
  cat > "$R/evil.spec" <<'SPEC'
Name: vmb-evil
Version: 1
Release: 1
Summary: vm-browser test package with a hostile .desktop file
License: MIT
BuildArch: noarch
%description
Test package for vm-browser's e2e test.
%install
mkdir -p %{buildroot}/usr/share/applications
printf '%%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Evil' 'Exec=/usr/bin/true;touch${IFS}/tmp/vmb-e2e-pwned %%U' > %{buildroot}/usr/share/applications/vmb-evil.desktop
%files
/usr/share/applications/vmb-evil.desktop
SPEC
  rpmbuild -bb --quiet --define "_topdir $R" "$R/evil.spec" >/dev/null 2>&1 || fail "could not build the test RPM"
  if out=$(./vm-browser.sh --name "$NAME" --rpm "$R"/RPMS/noarch/vmb-evil-1-1.noarch.rpm 2>&1); then
    fail "a hostile .desktop Exec was accepted"
  fi
  grep -q 'refusing the start command' <<< "$out" || fail "hostile RPM failed for another reason: $out"
  [ ! -e "$HOME/.local/bin/vmb-$NAME-vmb-evil" ] || fail "a launcher was written for the hostile RPM"
  rm -rf "$R"
  pass "an RPM whose .desktop Exec has shell code gets no launcher"
fi

# #9: when the last launcher closes, the VM shuts down; the next launch starts it again, and
# the network guard is back after that boot. "firefox --version" opens no window.
# launch ARGS: the launcher, limited to 5 minutes; on a timeout, show what it was waiting for.
launch() {
  local out rc; out=$(mktemp)
  timeout 300 "$L" "$@" > "$out" 2>&1; rc=$?
  if [ $rc = 124 ]; then
    echo "--- launcher timed out; its output:" >&2; cat "$out" >&2
    echo "--- processes:" >&2; ps -eo pid,ppid,etime,args --forest >&2 || true
  fi
  cat "$out"; rm -f "$out"; return $rc
}
launch --version >/dev/null || fail "the launcher could not run firefox --version"
for _ in $(seq 1 60); do [ "$(virsh domstate "$NAME")" = "shut off" ] && break; sleep 3; done
[ "$(virsh domstate "$NAME")" = "shut off" ] || fail "the VM is still running after its last launcher closed"
pass "the VM shut down after its last launcher closed"
launch --version | grep -q 'Mozilla Firefox' || fail "the launcher did not start the VM again"
VMB_KEEP_RUNNING=1 launch --version >/dev/null || true
"${ASSH[@]}" 'sudo nft list table inet vm_browser' >/dev/null || fail "the network guard is not loaded after a reboot"
pass "the launcher starts the VM again; the network guard is loaded at boot"
