# Testing

What was tested, where, and the result. Every pull request that changes the script runs ShellCheck, the unit checks in `tests/run.sh` (no VM needed) and the end-to-end test `tests/e2e.sh`, which builds a real Fedora VM on GitHub's runner. The end-to-end test also runs weekly. Running the checks yourself is covered in [CONTRIBUTING.md](CONTRIBUTING.md).

## File chooser in the VM, tested 2026-11-25

A Fedora 44 guest built by `vm-browser.sh` (weak dependencies off), Chromium 158, shown through waypipe on GNOME's mutter running headless on a Fedora 45 host. RHEL 10 and Prisma Access Browser were not run.

| Scenario | Result |
|---|---|
| No portal in the guest, no `libglvnd-gles`: click a file input | the browser aborts (SIGABRT in libepoxy, from GTK 4's own chooser) |
| Same, after installing `libglvnd-gles` | the "Open File" window appears; browser stays up |
| Existing VM without the package, `vm-browser.sh --name VM chromium` | the package is installed |
| Portal and its GTK backend installed, old launcher | no window; the backend is skipped for want of `WAYLAND_DISPLAY` |
| Same, new launcher | the backend starts and its "Open File" window appears |
| A second session after the first ended (new socket name) | the backend is restarted on the new display and its window appears |

Selecting a file in the chooser was not driven. The owner's own VM (RHEL 10.3, hand-built, not made by this script) showed the same missing-display failure, and the dialog appeared after setting `WAYLAND_DISPLAY` there by hand.

## Agent guidance, tested 2026-11-16

The two commands in AGENTS.md are the `shellcheck` and `tests` jobs of the `ci` workflow (Fedora 44 container), which passed on the pull request that added the file.

`tests/test_agentfiles.sh` has 49 unit checks. They feed the agent-file check hostile copies and it refuses each: a zero-width character, a right-to-left override, an escape sequence, a carriage return, an HTML comment, five forms of `@` import, a file over 60 lines, extra text in CLAUDE.md, and CLAUDE.md as a symlink. It also refuses fifteen other agent files, each both in a plain directory and tracked in a git checkout: `CLAUDE.local.md`, `AGENTS.override.md`, nested `CLAUDE.md` and `AGENTS.md`, `.mcp.json`, settings, rules and commands under `.claude/` (including `settings.local.json` and `.Claude/`), names with a double quote or a non-ASCII byte, and `.claude` as a symlink. Untracked local settings in a git checkout pass.

## RHEL 10 desktop, tested 2026-11-16

A RHEL 10.2 VM (KVM, registered, BaseOS and AppStream only) stood in for the desktop: libvirt 12.5, passt, xorriso 1.5.6, waypipe 0.8.6, and GNOME's mutter 49 running headless as the compositor. The quick start's `dnf install` line installed everything without EPEL.

| Scenario | Result |
|---|---|
| `tests/e2e.sh`, Fedora 44 cloud image (downloaded and verified): all checks, including the hostile `~/.ssh/config`, `--lan`, disposable mode, `--update` and `--persistent` | pass (17 checks) |
| `tests/e2e.sh`, RHEL 10.2 KVM image with an activation key: all checks, including the activation key found nowhere in the VM | pass (17 checks) |
| Fedora 45 netinstall ISO (`--version 45`): kernel and initrd read from the ISO with xorriso, installed through the metalink | pass |
| Firefox opened through the launcher on mutter: it ran with the forwarded Wayland display for over 6 minutes; closing it ended the launcher and shut the VM down | pass |

RHEL's waypipe 0.8 starts the VM's waypipe 0.11 only if the browser user's SSH sessions have `XDG_RUNTIME_DIR`, which needs `systemd-pam` in the guest; guests install it, and `tests/e2e.sh` checks for it. RHEL 9 desktops have the same packages (checked against CentOS Stream 9) but weren't run.

## Disposable mode, tested 2026-11-14

On GitHub's runner (Fedora 44 container with KVM), `tests/e2e.sh` makes the e2e VM disposable and checks:

- that its disk becomes a read-only base under an empty overlay;
- that a session's files, written as the browser user and as root, are gone in the next session, along with root disabling the network guard;
- that a script run refuses while the VM runs, and that its changes reach later sessions;
- `--update` and `--persistent`.

Result: pass. `tests/run.sh` has 26 unit checks for the overlay and maintenance logic, including interrupted saves and launchers closing during a run.

## Security changes, tested 2026-11-14

Tested on a Fedora 45 desktop (GNOME 51, libvirt user session, passt, waypipe 0.11.2), and on GitHub's runner (Fedora 44 container with KVM, headless Sway). `tests/e2e.sh` builds a VM, then checks:

- the launcher and the unprivileged `browser` login;
- the network guard: the desktop's loopback, the LAN, and the desktop's other addresses even with `--lan`, each with a control that the address opens without the guard;
- the pinned host key and the separate keys;
- that a hostile RPM gets no launcher;
- the shutdown after the last window closes, and the restart.

`tests/run.sh` runs 148 unit checks that need no VM.

| Scenario | Where | Result |
|---|---|---|
| Fedora 44 cloud image, downloaded and verified against the pinned key: Firefox, all e2e checks, LAN checks against a NAS and the desktop's libvirt bridge | desktop | pass |
| The same, plus a hostile `~/.ssh/config` and Firefox opened through the launcher on a headless Sway (window seen with security context `vm-browser.<vm>`) | GitHub runner | pass |
| RHEL 10.2 boot ISO with activation key (kickstart): Firefox 153 ESR, all e2e checks, and the activation key found nowhere in the VM | desktop | pass |
| Fedora 45 netinstall ISO (metalink): Firefox. 447 of 448 installed packages are signed by the Fedora 45 key; the other is the key itself | desktop | pass |
| GNOME 51: the launcher's probe finds no `wp_security_context_v1`, and waypipe runs without `--secctx` | desktop | pass |
| Fedora 44: Chrome 157, Chromium 156 and Brave 1.99 in one VM, Prisma Access Browser 157.19 in its own. Launchers built from each package (name, icon, window class), each browser started through its launcher. Run before the review fixes | desktop | pass |

## Browsers, tested 2026-11-13

On a Fedora 45 desktop (libvirt user session, passt, waypipe 0.11). Every scenario completed unattended. Each launcher's command was then run as the `browser` user over its own SSH settings. These runs predate the security changes above.

| Scenario | Result | Disk file | Browser versions |
|---|---|---|---|
| Fedora 44 cloud image: Chrome, Chromium, Brave, Firefox, Prisma | pass | 4.5 GB | Chrome 157, Chromium 156, Brave 1.99, Firefox 160, Prisma 157.19 |
| RHEL 10 KVM image + activation key: Firefox, Chromium (EPEL) | pass | 4.3 GB | Firefox 153 ESR, Chromium 156 |
| Fedora 44 Server DVD ISO (kickstart): Firefox | pass | 2.5 GB | Firefox 160 |
| RHEL 10 DVD ISO (kickstart) + activation key: Prisma from `--rpm` | pass | 4.0 GB | Prisma 157.19; protection service active, SELinux enforcing |
| Fedora 43 downloaded and GPG-verified: Firefox | pass | 2.2 GB | Firefox 159 |

Windows opened on the desktop for Prisma Access Browser (Fedora and RHEL guests) and Google Chrome (Fedora guest). Chrome felt somewhat slower than a native browser because it renders on the VM's CPU. Chromium, Brave and Firefox were checked with `--version`.
