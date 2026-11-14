# vm-browser

[![CI](https://github.com/aclater/vm-browser/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/aclater/vm-browser/actions/workflows/ci.yml)
[![CodeQL](https://github.com/aclater/vm-browser/actions/workflows/codeql.yml/badge.svg?branch=main)](https://github.com/aclater/vm-browser/actions/workflows/codeql.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/aclater/vm-browser/badge)](https://scorecard.dev/viewer/?uri=github.com/aclater/vm-browser)

Run a web browser inside a small, isolated Fedora or RHEL virtual machine, with its window on your normal Linux desktop.

The browser and anything it installs stay inside the VM: root services, kernel hooks, repo jobs and system changes. That suits browsers whose installers change more than you'd like on your workstation, such as enterprise browsers with their own protection services, as well as everyday browsing you want kept apart.

- **Browsers:** Google Chrome, Chromium, Brave, Firefox and Prisma Access Browser, or any browser RPM you pass with `--rpm`.
- **Guest OS:** Fedora or RHEL, any version. It starts from a cloud/KVM image or installs unattended from an installer ISO.
- **No root needed** after installing a few packages. Everything runs in your own libvirt session.
- **Small:** about 3–5 GB of disk (thin-provisioned) and roughly 1 GB of RAM with a few tabs open.
- **Runs only while used:** the VM starts when you open a browser and shuts down when you close the last one.
- **Self-updating:** while it runs, the VM installs OS and browser updates daily and reboots when an update needs it.

## How it works

```
your desktop (Wayland)                             VM (libvirt user session)
┌──────────────────────┐   waypipe over SSH     ┌──────────────────────────────┐
│ app menu → launcher  │ ───────────────────▶  │ user "browser" (no sudo)     │
│ browser window       │ ◀───────────────────  │   └─ chrome / firefox / …    │
└──────────────────────┘   127.0.0.1:<port>     │ user "admin" (sudo, key only)│
                                                └──────────────────────────────┘
```

- **Networking:** the VM uses `passt`. Its SSH is forwarded to `127.0.0.1` only, so it isn't reachable from your network.
- **What the VM can reach:** passt hands the VM's traffic for its gateway address to your desktop's `127.0.0.1`, and its traffic for any of your desktop's other addresses (libvirt and container bridges, VPNs, other interfaces) to the desktop itself, past its firewall. Without a guard that would expose every service listening there: printing (CUPS), keyboard and mouse sharing, other VMs' SSH ports, development servers. A firewall inside the VM (an nftables table) rejects:
  - **always:** the gateway, your desktop's own addresses, multicast and broadcast;
  - **unless you pass `--lan`:** private, shared and link-local ranges (`10/8`, `172.16/12`, `192.168/16`, `100.64/10`, `169.254/16`, `fc00::/7`, `fe80::/10`) and the VM's on-link networks, including the LAN's global IPv6 prefix, so your LAN, router and NAS are out of reach.

  DNS, DHCP, IPv6 neighbour discovery and the internet work. The table is loaded at every boot before the VM's SSH server starts, and again when the VM's network changes, and launchers start a browser only once it is active. Until the VM has a gateway, it rejects all IPv4 but DHCP. Your desktop's addresses are taken when you run `vm-browser.sh` and can change later (a new VPN, a new IPv6 temporary address): run the script again for the VM to refresh them. Each run sets the LAN rule too, so a later run without `--lan` blocks the LAN again. The rules are enforced inside the VM: they stop the browser, which has no root rights, but a root compromise of the VM could remove them.
- **Users:** the browser runs as an unprivileged `browser` user, which the launchers reach with their own SSH key. Admin work uses a separate `admin` account with a different key and no password.
- **Host key:** the script makes the VM's SSH host key itself and pins it in `known_hosts` before the VM first boots. Nothing else that might be listening on the local port is trusted with commands or credentials.
- **SSH:** every connection to the VM, including the launchers', uses `ssh -F none`, so your `~/.ssh/config` and `/etc/ssh/ssh_config.d` don't apply. A `Host *` block there can't forward your SSH agent or X11 display into the VM.
- **Repositories:** each browser comes from its vendor's signed repository (Google, Brave, Palo Alto Networks), or from Fedora/EPEL for Chromium and Firefox.
- **Launchers:** each is built from the package's own `.desktop` file (name, command, icon and window class), so it appears in your app menu with the browser's real icon. The VM's answers are treated as hostile: the start command must be a plain path (letters, digits and `._+-/`) or the launcher isn't written, it goes into the launcher as a quoted value rather than code, and names are stripped of control characters.

## Requirements

- **Desktop:** Fedora (or similar) running Wayland, with KVM.
- **Host packages:**
  ```bash
  sudo dnf install libvirt-client libvirt-daemon-kvm qemu-kvm qemu-img passt waypipe genisoimage openssh-clients curl gnupg2
  ```
- **RHEL guests** also need a Red Hat account: an [activation key and org ID](https://console.redhat.com/insights/connector/activation-keys), plus the RHEL KVM guest image or DVD ISO from [access.redhat.com](https://access.redhat.com/downloads). 

## Usage

```bash
# Fedora 44 (downloaded and GPG-verified automatically) with Firefox and Chrome, in a VM named "personal"
./vm-browser.sh --name personal firefox chrome

# Add Brave to the same VM later
./vm-browser.sh --name personal brave

# Work browsing in its own VM
./vm-browser.sh --name work prisma

# RHEL 10 from the KVM guest image, registered with an activation key
printf 'org=1234567\nkey=my-activation-key\n' > ~/.config/rhsm-activation && chmod 600 ~/.config/rhsm-activation
./vm-browser.sh --os rhel --image ~/Downloads/rhel-10.2-x86_64-kvm.qcow2 --rhsm ~/.config/rhsm-activation firefox

# Install from an installer ISO instead (unattended kickstart install)
./vm-browser.sh --image ~/Downloads/Fedora-Server-dvd-x86_64-44-1.7.iso firefox

# A browser from a local RPM
./vm-browser.sh --rpm ~/Downloads/some-browser.x86_64.rpm

```

**Use one VM per trust level.** All browsers in a VM run as the same `browser` user, so a browser that gets compromised can read the other browsers' profiles, cookies and signed-in sessions. Keep work browsing (for example Prisma Access Browser and its corporate sessions) and personal browsing in separate VMs with `--name`. The script warns when Prisma Access Browser and other browsers would share a VM.

| Option | Default | Meaning |
|---|---|---|
| `--os fedora\|rhel` | `fedora` | Guest distribution |
| `--version N` | 44 (Fedora), 10 (RHEL) | Release |
| `--image PATH` | Fedora: downloaded | A `.qcow2` cloud/KVM image or an installer `.iso` |
| `--rhsm FILE` | — | RHEL registration file (`org=…` and `key=…`) |
| `--rpm FILE` | — | Install a browser from a local RPM (repeatable) |
| `--name NAME` | `<os><version>-browsers` | VM name (letters, digits and hyphens); use different names for separate VMs |
| `--port N` | first free from 2230 | Local SSH port |
| `--memory GiB` / `--cpus N` / `--disk SIZE` | 4 / 4 / 12G | VM size (the disk is thin-provisioned) |
| `--lan` | off | Let the VM reach your local network. Your desktop's loopback and its own addresses stay blocked. Applies to this run: a later run without it blocks the LAN again |

Each browser gets a menu entry called **"&lt;Browser name&gt; (&lt;VM name&gt;)"**, with a script in `~/.local/bin/vmb-<vm>-<package>`.

### Daily use

- **Open a browser:** use its menu entry. The VM starts automatically.
- **Close it:** when the last browser window of a VM closes, the VM shuts down, after any update that is running in it has finished. To keep it running, start the launcher with `VMB_KEEP_RUNNING=1`, or stop it by hand: `virsh -c qemu:///session shutdown <vm>`.
- **Admin shell:** `ssh -F none -i ~/.local/share/vm-browser/<vm>/id_ed25519 -o UserKnownHostsFile=~/.local/share/vm-browser/<vm>/known_hosts -p <port> admin@127.0.0.1` (the port is in `~/.local/share/vm-browser/<vm>/port`).
- **Remove a VM:**
  ```bash
  virsh -c qemu:///session destroy <vm>; virsh -c qemu:///session undefine <vm> --remove-all-storage
  rm -rf ~/.local/share/vm-browser/<vm> ~/.local/bin/vmb-<vm>-* ~/.local/share/applications/vmb-<vm>-*.desktop
  ```

## Notes

- **Prisma Access Browser** installs a root service that loads eBPF hooks to protect the browser's processes. If the kernel's security-module list lacks `bpf`, its installer rewrites the boot command line in a way that drops SELinux. The script checks for `bpf` first and refuses to continue without it. Current Fedora and RHEL kernels include it.
- **Images and RPMs you supply aren't verified by the script:** `--image` files (all RHEL images, and Fedora ISOs) and `--rpm` packages are used as they are. Check them first, for example against the vendor's published SHA-256 checksum (`sha256sum FILE`) or with `rpm -K FILE` for an RPM signed with a key you have imported.
- **Fedora image downloads** are used only if the release's `CHECKSUM` file is signed by that release's key, and only the signed part of the file is read. The key fingerprints for Fedora 42–47 are pinned in the script (`FEDORA_KEYS`). For any other release, the script stops: pass `--image` with an image you've verified, or add the release's key.
- **Chromium on RHEL** comes from EPEL, so the script enables CodeReady Builder and EPEL.
- **ISO installs** boot the installer kernel straight from the ISO and supply a kickstart on a second virtual disc labelled `OEMDRV`, so `virt-install` isn't needed. DVD ISOs install from the disc. Fedora netinstall ISOs use Fedora's mirrors through a metalink, which pins the hash of the repository metadata (and so of every package), and RHEL boot ISOs register with the activation key during installation. The install files that hold the key are deleted however the install ends, and the copies Anaconda leaves in the VM are removed during setup.
- **Automatic updates** use `dnf5-automatic` on Fedora and `dnf-automatic` on RHEL. Because the VM is off while no browser is open, a daily run it missed happens within an hour of its next start, and a reboot it needs closes any open browser window.
- **The VM is kept between sessions:** its disk persists, so anything that compromises it stays until you remove the VM and create it again (see "Remove a VM"). Stopping it when you're done means it isn't online in between. A disposable mode that discards changes at shutdown is tracked in [#9](https://github.com/aclater/vm-browser/issues/9).
- **Display:** the browser renders on the VM's CPU, since there's no GPU passthrough. That's fine for documents and web apps, but not for games or heavy video.
- **Windows and the clipboard:** the browser's windows reach your desktop through waypipe, as an ordinary Wayland client. While one of them has focus it can read your clipboard, including a password you've just copied, and it can draw any window, so a compromised browser could imitate a login or system dialog. Launchers ask for a security context (`waypipe --secctx vm-browser.<vm>`), so compositors that support it, such as Sway and Hyprland, can identify these windows and withhold privileged protocols: screen capture, virtual keyboards and clipboard managers. Each launch first checks, on your desktop and without asking the VM, whether the compositor offers the protocol. GNOME (checked on GNOME 51) doesn't, so launchers there run without it. GNOME doesn't give those privileged protocols to ordinary windows either, which leaves the clipboard and look-alike windows.

## Status

### Security changes, tested 2026-11-14

Tested on a Fedora 45 desktop (GNOME 51, libvirt user session, passt, waypipe 0.11.2), and on GitHub's runner (Fedora 44 container with KVM). `tests/e2e.sh` builds a VM, then checks the launcher, the network guard, the keys, a hostile RPM and the shutdown after the last window closes. `tests/run.sh` runs 92 unit checks that need no VM.

| Scenario | Where | Result |
|---|---|---|
| Fedora 44 cloud image, downloaded and verified against the pinned key: Firefox, all e2e checks, LAN check against a NAS | desktop | pass |
| The same, plus a hostile `~/.ssh/config` and Firefox opened through the launcher on a headless Sway (window seen with security context `vm-browser.<vm>`) | GitHub runner | pass |
| RHEL 10.2 boot ISO with activation key (kickstart): Firefox 153 ESR, all e2e checks, and the activation key found nowhere in the VM | desktop | pass |
| Fedora 45 netinstall ISO (metalink): Firefox. 447 of 448 installed packages are signed by the Fedora 45 key; the other is the key itself | desktop | pass |
| GNOME 51: `waypipe --secctx` refused (no `wp_security_context_v1`), launcher falls back to plain waypipe | desktop | pass |
| Fedora 44: Chrome 157, Chromium 156 and Brave 1.99 in one VM, Prisma Access Browser 157.19 in its own. Launchers built from each package (name, icon, window class), each browser started through its launcher | desktop | pass |

### Browsers, tested 2026-11-13

Tested 2026-11-13 on a Fedora 45 desktop (libvirt user session, passt, waypipe 0.11). Every scenario completed unattended. Each launcher's command was then run as the `browser` user over its own SSH settings. These runs predate the security changes above.

| Scenario | Result | Disk file | Browser versions |
|---|---|---|---|
| Fedora 44 cloud image: Chrome, Chromium, Brave, Firefox, Prisma | pass | 4.5 GB | Chrome 157, Chromium 156, Brave 1.99, Firefox 160, Prisma 157.19 |
| RHEL 10 KVM image + activation key: Firefox, Chromium (EPEL) | pass | 4.3 GB | Firefox 153 ESR, Chromium 156 |
| Fedora 44 Server DVD ISO (kickstart): Firefox | pass | 2.5 GB | Firefox 160 |
| RHEL 10 DVD ISO (kickstart) + activation key: Prisma from `--rpm` | pass | 4.0 GB | Prisma 157.19; protection service active, SELinux enforcing |
| Fedora 43 downloaded and GPG-verified: Firefox | pass | 2.2 GB | Firefox 159 |

Windows opened on the desktop for Prisma Access Browser (Fedora and RHEL guests) and Google Chrome (Fedora guest). Chrome felt somewhat slower than a native browser because it renders on the VM's CPU. Chromium, Brave and Firefox were checked with `--version`.

## Security and contributing

Report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md). Changes and their
tests are covered in [CONTRIBUTING.md](CONTRIBUTING.md).
