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
cleanup() {
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

# The launcher's own ssh command, as the browser user: everything but its last exec line.
SSH_LINE=$(grep '^SSH=' "$L")
eval "$SSH_LINE"
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
