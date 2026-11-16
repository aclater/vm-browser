# vm-browser

[![CI](https://github.com/aclater/vm-browser/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/aclater/vm-browser/actions/workflows/ci.yml)
[![CodeQL](https://github.com/aclater/vm-browser/actions/workflows/codeql.yml/badge.svg?branch=main)](https://github.com/aclater/vm-browser/actions/workflows/codeql.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/aclater/vm-browser/badge)](https://scorecard.dev/viewer/?uri=github.com/aclater/vm-browser)

Run a web browser inside a small, isolated Fedora or RHEL virtual machine, with its window on your normal Linux desktop.

The browser and anything it installs stay inside the VM: root services, kernel hooks, repository jobs and system changes. That suits browsers whose installers change more than you'd like on your workstation, such as enterprise browsers with their own protection services, as well as everyday browsing you want kept apart.

- **Browsers:** Google Chrome, Chromium, Brave, Firefox and Prisma Access Browser, or any browser RPM you pass with `--rpm`.
- **Guest OS:** Fedora or RHEL, from a cloud/KVM image or an unattended install from an installer ISO.
- **No root needed** after installing a few packages. Everything runs in your own libvirt session.
- **Small:** about 3–5 GB of disk and roughly 1 GB of RAM with a few tabs open.
- **Runs only while used:** the VM starts when you open a browser and shuts down when you close the last one.
- **Self-updating:** while it runs, the VM installs OS and browser updates daily.

## Quick start

You need a Fedora or RHEL 10 desktop running Wayland, with KVM, 4 GB of free memory and 5 GB of free disk space. On RHEL, every package comes from the standard BaseOS and AppStream repositories.

1. Install the packages and get the script:

   ```
   sudo dnf install -y git libvirt-client libvirt-daemon-kvm qemu-kvm qemu-img passt waypipe xorriso openssh-clients curl gnupg2 iproute
   git clone https://github.com/aclater/vm-browser.git
   cd vm-browser
   ```

2. Make a VM named `personal` with Firefox in it:

   ```
   ./vm-browser.sh --name personal firefox
   ```

   The script downloads Fedora 44, checks its signature, builds the VM and installs Firefox. The first run takes several minutes.

3. Open **Firefox (personal)** from your app menu. The VM starts with it and shuts down when you close the last window.

| If you want to | Go to |
|---|---|
| Add Chrome, Brave or Chromium | [Usage](#usage) |
| Keep work and personal browsing apart | [One VM per trust level](#one-vm-per-trust-level) |
| Run RHEL in the VM | [RHEL guests](#rhel-guests) |
| Throw away everything a session changed | [Disposable VMs](#disposable-vms) |
| Let the VM reach your local network | `--lan` under [Options](#options) |
| Remove a VM | [Daily use](#daily-use) |

## Usage

```bash
# Add Chrome and Brave to the VM "personal"
./vm-browser.sh --name personal chrome brave

# Work browsing in its own VM
./vm-browser.sh --name work prisma

# Install from a Fedora installer ISO instead of the cloud image (unattended kickstart install)
./vm-browser.sh --name fedora-dvd --image ~/Downloads/Fedora-Server-dvd-x86_64-44-1.7.iso firefox

# A browser from a local RPM
./vm-browser.sh --name personal --rpm ~/Downloads/some-browser.x86_64.rpm
```

Each browser gets a menu entry called **"&lt;Browser name&gt; (&lt;VM name&gt;)"** and a script in `~/.local/bin/vmb-<vm>-<package>`. Run the script again with more browsers to add them to an existing VM.

### One VM per trust level

All browsers in a VM run as the same `browser` user, so a browser that gets compromised can read the other browsers' profiles, cookies and signed-in sessions. Keep work browsing (for example Prisma Access Browser and its corporate sessions) and personal browsing in separate VMs with `--name`. The script warns when Prisma Access Browser and other browsers would share a VM.

### RHEL guests

RHEL guests need a Red Hat account: an [activation key and org ID](https://console.redhat.com/insights/connector/activation-keys), and the RHEL KVM guest image or an installer ISO from [access.redhat.com](https://access.redhat.com/downloads). Put the org ID and key in a file only you can read, and pass it with `--rhsm`:

```bash
printf 'org=1234567\nkey=my-activation-key\n' > ~/.config/rhsm-activation && chmod 600 ~/.config/rhsm-activation
./vm-browser.sh --name work --os rhel --image ~/Downloads/rhel-10.2-x86_64-kvm.qcow2 --rhsm ~/.config/rhsm-activation prisma
```

The script registers the VM with the key.

### Options

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
| `--disposable` | off | Start every session from the installed system and discard the session's changes when the VM stops (see [Disposable VMs](#disposable-vms)). Stays on for later runs |
| `--persistent` | on | Keep the VM's disk between sessions again |
| `--update` | — | Install the guest's updates now. Needs no browser |

## Daily use

- **Open a browser:** use its menu entry. The VM starts automatically.
- **Close it:** when the last browser window of a VM closes, the VM shuts down, after any update running in it has finished (a disposable VM doesn't wait: it loses the update anyway). A VM that hasn't shut down two minutes after being asked is switched off, since a compromised VM could ignore the request. To keep it running, start the launcher with `VMB_KEEP_RUNNING=1`, and stop it by hand with `virsh -c qemu:///session shutdown <vm>`.
- **Update a VM by hand:** `./vm-browser.sh --name <vm> --update`.
- **Admin shell:** `ssh -F none -i ~/.local/share/vm-browser/<vm>/id_ed25519 -o UserKnownHostsFile=~/.local/share/vm-browser/<vm>/known_hosts -p <port> admin@127.0.0.1` (the port is in `~/.local/share/vm-browser/<vm>/port`).
- **Remove a VM:**
  ```bash
  virsh -c qemu:///session destroy <vm> 2>/dev/null; virsh -c qemu:///session undefine <vm>
  rm -rf ~/.local/share/vm-browser/<vm> ~/.local/bin/vmb-<vm>-* ~/.local/share/applications/vmb-<vm>-*.desktop
  ```

## Disposable VMs

By default a VM keeps its disk, so anything that compromises it stays until you remove the VM and create it again. With `--disposable`, nothing a session changes is kept:

```bash
./vm-browser.sh --name personal --disposable firefox   # a new VM, or an existing one that is shut off
./vm-browser.sh --name personal --update               # now and then: updates into the installed system
```

- **How it works:** the installed system is kept read-only in `~/.local/share/vm-browser/<vm>/base.qcow2`. Each session runs on an empty overlay, `disk.qcow2`. The launcher makes a new overlay before it starts the VM, and again after the VM stops, so a session's changes are discarded, even changes made as root.
- **What you lose:** downloads, browser profiles, bookmarks, saved passwords and sign-ins. Every session starts like a fresh install. This suits personal or one-off browsing, and suits a work browser you sign into every day less well: Prisma Access Browser needs you to sign in again in each session.
- **Updates:** a session installs the day's updates as usual but loses them at shutdown, and never reboots for them. Run `--update` to install them into the installed system. The launcher shows a desktop notification when that is more than a week old.
- **Script runs** (adding a browser, `--update`, `--lan`) change the installed system. They need the VM shut off with no browser open, and launchers refuse to start until the run has finished. If a run fails, its changes are discarded. If it is interrupted while saving them into the installed system, launchers refuse to start until the next run (for example `--update`) has finished the save.
- **An existing VM** made disposable keeps its current disk as the installed system, including anything a past session left there. To start clean, remove the VM and create it again with `--disposable`.
- `--persistent` makes the VM keep its disk again.

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
- **Network guard:** passt hands the VM's traffic for its gateway address to your desktop's `127.0.0.1`, and its traffic for your desktop's other addresses (libvirt and container bridges, VPNs, other interfaces) to the desktop itself, past its firewall. Without a guard that would expose every service listening there: printing (CUPS), keyboard and mouse sharing, other VMs' SSH ports, development servers. A firewall inside the VM (an nftables table) rejects:
  - **always:** the gateway, your desktop's own addresses, multicast and broadcast;
  - **unless you pass `--lan`:** private, shared and link-local ranges (`10/8`, `172.16/12`, `192.168/16`, `100.64/10`, `169.254/16`, `fc00::/7`, `fe80::/10`) and the VM's on-link networks, including the LAN's global IPv6 prefix, so your LAN, router and NAS are out of reach.

  DNS, DHCP, IPv6 neighbour discovery and the internet work. The table is loaded at every boot before the VM's SSH server starts, and again when the VM's network changes, and launchers start a browser only once it is active. Until the VM has a gateway, it rejects all IPv4 but DHCP. Your desktop's addresses are taken when you run `vm-browser.sh` and can change later (a new VPN, a new IPv6 temporary address): run the script again for the VM to refresh them. The rules are enforced inside the VM: they stop the browser, which has no root rights, but a root compromise of the VM could remove them.
- **Users:** the browser runs as an unprivileged `browser` user, which the launchers reach with their own SSH key. Admin work uses a separate `admin` account with a different key and no password.
- **Host key:** the script makes the VM's SSH host key itself and pins it in `known_hosts` before the VM first boots. Nothing else that might be listening on the local port is trusted with commands or credentials.
- **SSH:** every connection to the VM, including the launchers', uses `ssh -F none`, so your `~/.ssh/config` and `/etc/ssh/ssh_config.d` don't apply. A `Host *` block there can't forward your SSH agent or X11 display into the VM.
- **Repositories:** each browser comes from its vendor's signed repository (Google, Brave, Palo Alto Networks), or from Fedora/EPEL for Chromium and Firefox.
- **Launchers:** each is built from the package's own `.desktop` file (name, command, icon and window class), so it appears in your app menu with the browser's real icon. The VM's answers are treated as hostile: the start command must be a plain path (letters, digits and `._+-/`) or the launcher isn't written, it goes into the launcher as a quoted value rather than code, and names are stripped of control characters.

## Notes and limitations

- **Windows and the clipboard:** the browser's windows reach your desktop through waypipe, as an ordinary Wayland client. While one of them has focus it can read your clipboard, including a password you've just copied, and it can draw any window, so a compromised browser could imitate a login or system dialog. Launchers ask for a security context (`waypipe --secctx vm-browser.<vm>`), so compositors that support it, such as Sway and Hyprland, can identify these windows and withhold privileged protocols: screen capture, virtual keyboards and clipboard managers. Each launch first checks, on your desktop and without asking the VM, whether the compositor offers the protocol. GNOME (checked on GNOME 51) doesn't, so launchers there run without it. RHEL's waypipe (0.8) has no `--secctx` at all, so on RHEL launchers always run without it. GNOME doesn't give those privileged protocols to ordinary windows either, which leaves the clipboard and look-alike windows.
- **Images and RPMs you supply aren't verified by the script:** `--image` files (all RHEL images, and Fedora ISOs) and `--rpm` packages are used as they are. Check them first, for example against the vendor's published SHA-256 checksum (`sha256sum FILE`) or with `rpm -K FILE` for an RPM signed with a key you have imported.
- **Fedora image downloads** are used only if the release's `CHECKSUM` file is signed by that release's key, and only the signed part of the file is read. The key fingerprints for Fedora 42–47 are pinned in the script (`FEDORA_KEYS`). For any other release, the script stops: pass `--image` with an image you've verified, or add the release's key.
- **Prisma Access Browser** installs a root service that loads eBPF hooks to protect the browser's processes. If the kernel's security-module list lacks `bpf`, its installer rewrites the boot command line in a way that drops SELinux. The script checks for `bpf` first and refuses to continue without it. Current Fedora and RHEL kernels include it.
- **Chromium on RHEL** comes from EPEL, so the script enables CodeReady Builder and EPEL.
- **ISO installs** boot the installer kernel straight from the ISO and supply a kickstart on a second virtual disc labelled `OEMDRV`, so `virt-install` isn't needed. DVD ISOs install from the disc. Fedora netinstall ISOs use Fedora's mirrors through a metalink, which pins the hash of the repository metadata (and so of every package), and RHEL boot ISOs register with the activation key during installation. The install files that hold the key are deleted however the install ends, and the copies Anaconda leaves in the VM are removed during setup.
- **Automatic updates** use `dnf5-automatic` on Fedora and `dnf-automatic` on RHEL. Because the VM is off while no browser is open, a daily run it missed happens within an hour of its next start, and a reboot it needs closes any open browser window. Disposable VMs never reboot for updates.
- **Display:** the browser renders on the VM's CPU, since there's no GPU passthrough. That's fine for documents and web apps, but not for games or heavy video.

## Testing

Every pull request that changes the script runs ShellCheck, 148 unit checks that need no VM, and an end-to-end test that builds a real Fedora VM on GitHub's runner. [TESTING.md](TESTING.md) lists what was tested on a desktop and on the runner, with dates and results.

## Security and contributing

Report vulnerabilities privately, as described in [SECURITY.md](SECURITY.md). Changes and their tests are covered in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

vm-browser is licensed under the GNU General Public License, version 3 or (at your option) any later version ([LICENSE](LICENSE)).
