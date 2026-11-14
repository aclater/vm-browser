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
- **Self-updating:** the VM installs OS and browser updates daily and reboots when an update needs it.

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
- **Users:** the browser runs as an unprivileged `browser` user. Admin work uses a separate `admin` account with an SSH key and no password.
- **Repositories:** each browser comes from its vendor's signed repository (Google, Brave, Palo Alto Networks), or from Fedora/EPEL for Chromium and Firefox.
- **Launchers:** each is built from the package's own `.desktop` file (name, command, icon and window class), so it appears in your app menu with the browser's real icon.

## Requirements

- **Desktop:** Fedora (or similar) running Wayland, with KVM.
- **Host packages:**
  ```bash
  sudo dnf install libvirt-client libvirt-daemon-kvm qemu-kvm qemu-img passt waypipe genisoimage openssh-clients curl gnupg2
  ```
- **RHEL guests** also need a Red Hat account: an [activation key and org ID](https://console.redhat.com/insights/connector/activation-keys), plus the RHEL KVM guest image or DVD ISO from [access.redhat.com](https://access.redhat.com/downloads). 

## Usage

```bash
# Fedora 44 (downloaded and GPG-verified automatically) with Firefox and Chrome
./vm-browser.sh firefox chrome

# Add Brave to the same VM later
./vm-browser.sh brave

# RHEL 10 from the KVM guest image, registered with an activation key
printf 'org=1234567\nkey=my-activation-key\n' > ~/.config/rhsm-activation && chmod 600 ~/.config/rhsm-activation
./vm-browser.sh --os rhel --image ~/Downloads/rhel-10.2-x86_64-kvm.qcow2 --rhsm ~/.config/rhsm-activation firefox

# Install from an installer ISO instead (unattended kickstart install)
./vm-browser.sh --image ~/Downloads/Fedora-Server-dvd-x86_64-44-1.7.iso firefox

# A browser from a local RPM
./vm-browser.sh --rpm ~/Downloads/some-browser.x86_64.rpm

# Prisma Access Browser
./vm-browser.sh prisma
```

| Option | Default | Meaning |
|---|---|---|
| `--os fedora\|rhel` | `fedora` | Guest distribution |
| `--version N` | 44 (Fedora), 10 (RHEL) | Release |
| `--image PATH` | Fedora: downloaded | A `.qcow2` cloud/KVM image or an installer `.iso` |
| `--rhsm FILE` | — | RHEL registration file (`org=…` and `key=…`) |
| `--rpm FILE` | — | Install a browser from a local RPM (repeatable) |
| `--name NAME` | `<os><version>-browsers` | VM name; use different names for separate VMs |
| `--port N` | first free from 2230 | Local SSH port |
| `--memory GiB` / `--cpus N` / `--disk SIZE` | 4 / 4 / 12G | VM size (the disk is thin-provisioned) |

Each browser gets a menu entry called **"&lt;Browser name&gt; (&lt;VM name&gt;)"**, with a script in `~/.local/bin/vmb-<vm>-<package>`.

### Daily use

- **Open a browser:** use its menu entry. The VM starts automatically.
- **Stop the VM:** `virsh -c qemu:///session shutdown <vm>`
- **Admin shell:** `ssh -i ~/.local/share/vm-browser/<vm>/id_ed25519 -p <port> admin@127.0.0.1` (the port is in `~/.local/share/vm-browser/<vm>/port`).
- **Remove a VM:**
  ```bash
  virsh -c qemu:///session destroy <vm>; virsh -c qemu:///session undefine <vm> --remove-all-storage
  rm -rf ~/.local/share/vm-browser/<vm> ~/.local/bin/vmb-<vm>-* ~/.local/share/applications/vmb-<vm>-*.desktop
  ```

## Notes

- **Prisma Access Browser** installs a root service that loads eBPF hooks to protect the browser's processes. If the kernel's security-module list lacks `bpf`, its installer rewrites the boot command line in a way that drops SELinux. The script checks for `bpf` first and refuses to continue without it. Current Fedora and RHEL kernels include it.
- **Fedora image downloads** are used only if the release's `CHECKSUM` file is signed by that release's key, and only the signed part of the file is read. The key fingerprints for Fedora 42–47 are pinned in the script (`FEDORA_KEYS`). For any other release, the script stops: pass `--image` with an image you've verified, or add the release's key.
- **Chromium on RHEL** comes from EPEL, so the script enables CodeReady Builder and EPEL.
- **ISO installs** boot the installer kernel straight from the ISO and supply a kickstart on a second virtual disc labelled `OEMDRV`, so `virt-install` isn't needed. DVD ISOs install from the disc. Fedora netinstall ISOs use Fedora's mirrors through a metalink, which pins the hash of the repository metadata (and so of every package), and RHEL boot ISOs register with the activation key during installation.
- **Automatic updates** use `dnf5-automatic` on Fedora and `dnf-automatic` on RHEL. Their reboots close any open browser window.
- **Display:** the browser renders on the VM's CPU, since there's no GPU passthrough. That's fine for documents and web apps, but not for games or heavy video.

## Status

Tested 2026-11-13 on a Fedora 45 desktop (libvirt user session, passt, waypipe 0.11). Every scenario completed unattended. Each launcher's command was then run as the `browser` user over its own SSH settings.

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
