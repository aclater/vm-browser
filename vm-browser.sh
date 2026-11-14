#!/bin/bash
# vm-browser: run web browsers in a small, isolated Fedora or RHEL VM and show them on this desktop (Wayland, via waypipe).
# Runs as your normal user (libvirt user session). See README.md.
set -euo pipefail

usage() { cat <<'EOF'
Usage: vm-browser.sh [options] [BROWSER...]

Browsers: chrome  chromium  brave  firefox  prisma
  (run again with more browsers to add them to an existing VM)

Options:
  --os fedora|rhel     Distribution (default: fedora)
  --version N          Release, e.g. 44 or 10 (default: fedora 44, rhel 10)
  --image PATH         Cloud/KVM .qcow2 image or installer .iso.
                       Fedora: downloaded and verified if omitted. RHEL: required.
  --rhsm FILE          RHEL registration file with lines org=ORG_ID and key=ACTIVATION_KEY
  --rpm FILE           Install a browser from a local RPM (repeatable)
  --name NAME          VM name (default: <os><version>-browsers)
  --port N             Local SSH port (default: first free from 2230)
  --memory GiB         RAM (default 4)   --cpus N (default 4)   --disk SIZE (default 12G)
  -h, --help
EOF
}

OS=fedora VER="" IMAGE="" RHSM="" NAME="" PORT="" MEM=4 CPUS=4 DISK=12G
BROWSERS=() RPMS=()
parse_args() {
while [ $# -gt 0 ]; do
  case "$1" in
    --os) OS=$2; shift 2;; --version) VER=$2; shift 2;; --image) IMAGE=$(realpath "$2"); shift 2;;
    --rhsm) RHSM=$(realpath "$2"); shift 2;; --rpm) RPMS+=("$(realpath "$2")"); shift 2;;
    --name) NAME=$2; shift 2;; --port) PORT=$2; shift 2;; --memory) MEM=$2; shift 2;;
    --cpus) CPUS=$2; shift 2;; --disk) DISK=$2; shift 2;; -h|--help) usage; exit 0;;
    chrome|chromium|brave|firefox|prisma) BROWSERS+=("$1"); shift;;
    *) echo "Unknown argument: $1"; usage; exit 1;;
  esac
done
case "$OS" in fedora) VER=${VER:-44};; rhel) VER=${VER:-10};; *) echo "--os must be fedora or rhel"; exit 1;; esac
NAME=${NAME:-$OS$VER-browsers}
[ ${#BROWSERS[@]} -gt 0 ] || [ ${#RPMS[@]} -gt 0 ] || { echo "Choose at least one browser or --rpm."; usage; exit 1; }
}

log() { printf '\n== %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# State folder, keys and host tools. Separate from parse_args so the tests can source this file.
setup() {
  export LIBVIRT_DEFAULT_URI=qemu:///session
  DIR="$HOME/.local/share/vm-browser/$NAME"
  mkdir -p "$DIR"; chmod 700 "$DIR"
  KEYF="$DIR/id_ed25519"; KH="$DIR/known_hosts"
  for c in virsh qemu-img passt waypipe genisoimage isoinfo ssh scp curl gpgv gpg; do
    command -v "$c" >/dev/null || die "missing $c. Install: sudo dnf install libvirt-client libvirt-daemon-kvm qemu-kvm qemu-img passt waypipe genisoimage openssh-clients curl gnupg2"
  done
}

# ---------- VM creation (skipped if the VM already exists) ----------
create_vm() {
  [ -f "$KEYF" ] || ssh-keygen -q -t ed25519 -N '' -C "vm-browser-$NAME" -f "$KEYF"
  local key; key=$(cat "$KEYF.pub")
  if [ -z "$PORT" ]; then   # first port that is neither listening nor assigned to another vm-browser VM
    PORT=2230; while ss -Htln "sport = :$PORT" | grep -q . || cat "$HOME"/.local/share/vm-browser/*/port 2>/dev/null | grep -qx "$PORT"; do PORT=$((PORT+1)); done
  fi
  echo "$PORT" > "$DIR/port"

  if [ -z "$IMAGE" ]; then
    [ "$OS" = fedora ] || die "RHEL images need a Red Hat login. Download the KVM guest image or DVD ISO from access.redhat.com and pass --image."
    fetch_fedora_cloud
  fi
  case "$IMAGE" in
    *.iso) install_from_iso "$key";;
    *.qcow2|*.img) install_from_cloud_image "$key";;
    *) die "--image must be a .qcow2 or .iso";;
  esac
}

fetch_fedora_cloud() {
  local base="https://dl.fedoraproject.org/pub/fedora/linux/releases/$VER/Cloud/x86_64/images"
  log "Finding the Fedora $VER Cloud image"
  local sumf; sumf=$(curl -fsSL "$base/" | grep -oE "Fedora-Cloud-$VER-[0-9.]+-x86_64-CHECKSUM" | sort -uV | tail -1)
  [ -n "$sumf" ] || die "no Fedora $VER Cloud image found at $base"
  curl -fsSL -o "$DIR/CHECKSUM" "$base/$sumf"
  curl -fsSL https://fedoraproject.org/fedora.gpg | gpg --dearmor > "$DIR/fedora.gpg"
  gpgv --keyring "$DIR/fedora.gpg" "$DIR/CHECKSUM" 2>/dev/null || die "CHECKSUM signature did not verify"
  local img; img=$(grep -oE "Fedora-Cloud-Base-Generic-$VER-[0-9.]+\.x86_64\.qcow2" "$DIR/CHECKSUM" | head -1)
  log "Downloading $img"
  curl -fL -o "$DIR/$img" "https://download.fedoraproject.org/pub/fedora/linux/releases/$VER/Cloud/x86_64/images/$img"
  (cd "$DIR" && grep -E "^SHA256 \($img\)" CHECKSUM | sha256sum -c -) || die "image checksum mismatch"
  IMAGE="$DIR/$img"; DOWNLOADED=1
}

domain_xml() {  # $1 = extra <os> lines, $2 = extra devices
  cat <<EOF
<domain type='kvm'>
  <name>$NAME</name>
  <description>vm-browser: $OS $VER</description>
  <memory unit='GiB'>$MEM</memory>
  <vcpu>$CPUS</vcpu>
  <os><type arch='x86_64' machine='q35'>hvm</type>$1<boot dev='hd'/></os>
  <features><acpi/><apic/></features>
  <cpu mode='host-passthrough'/>
  <on_reboot>restart</on_reboot>
  <devices>
    <disk type='file' device='disk'><driver name='qemu' type='qcow2' discard='unmap'/><source file='$DIR/disk.qcow2'/><target dev='vda' bus='virtio'/></disk>
    $2
    <interface type='user'>
      <backend type='passt'/>
      <portForward proto='tcp' address='127.0.0.1'><range start='$PORT' to='22'/></portForward>
      <model type='virtio'/>
    </interface>
    <serial type='pty'/><console type='pty'/>
    <rng model='virtio'><backend model='random'>/dev/urandom</backend></rng>
    <memballoon model='virtio'/>
  </devices>
</domain>
EOF
}

install_from_cloud_image() {
  log "Creating the VM from $(basename "$IMAGE")"
  if [ "${DOWNLOADED:-0}" = 1 ]; then mv "$IMAGE" "$DIR/disk.qcow2"; else cp --sparse=always "$IMAGE" "$DIR/disk.qcow2"; fi
  qemu-img resize -q "$DIR/disk.qcow2" "$DISK"
  cat > "$DIR/user-data" <<EOF
#cloud-config
hostname: $NAME
ssh_pwauth: false
users:
  - name: admin
    groups: [wheel]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys: ["$1"]
EOF
  printf 'instance-id: %s\nlocal-hostname: %s\n' "$NAME" "$NAME" > "$DIR/meta-data"
  genisoimage -quiet -o "$DIR/seed.iso" -V cidata -J -r "$DIR/user-data" "$DIR/meta-data"
  domain_xml "" "<disk type='file' device='cdrom'><driver name='qemu' type='raw'/><source file='$DIR/seed.iso'/><target dev='sda' bus='sata'/><readonly/></disk>" > "$DIR/domain.xml"
  virsh define "$DIR/domain.xml" >/dev/null && virsh start "$NAME" >/dev/null
}

install_from_iso() {
  log "Installing $OS $VER from $(basename "$IMAGE") (unattended; 10-30 minutes)"
  local label src="" lesc
  label=$(isoinfo -d -i "$IMAGE" | sed -n 's/^Volume id: //p')
  lesc=$(printf '%s' "$label" | sed 's/ /\\x20/g')
  isoinfo -R -i "$IMAGE" -x /images/pxeboot/vmlinuz > "$DIR/vmlinuz"
  isoinfo -R -i "$IMAGE" -x /images/pxeboot/initrd.img > "$DIR/initrd.img"
  [ -s "$DIR/vmlinuz" ] && [ -s "$DIR/initrd.img" ] || die "no installer kernel in $IMAGE"
  if isoinfo -R -f -i "$IMAGE" | grep -qE '^/(BaseOS/repodata|repodata|Packages)$'; then src="cdrom"
  elif [ "$OS" = fedora ]; then src="url --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-$VER&arch=x86_64"
  else
    [ -n "$RHSM" ] || die "this RHEL boot ISO has no packages; pass --rhsm so the installer can use the Red Hat CDN"
    src="rhsm --organization=$(sed -n 's/^org=//p' "$RHSM") --activation-key=$(sed -n 's/^key=//p' "$RHSM")"
  fi
  mkdir -p "$DIR/ks"; ( umask 077; cat > "$DIR/ks/ks.cfg" <<EOF
text
$src
lang en_US.UTF-8
keyboard us
timezone UTC --utc
network --bootproto=dhcp --hostname=$NAME
rootpw --lock
user --name=admin --groups=wheel --lock
sshkey --username=admin "$1"
selinux --enforcing
firstboot --disable
zerombr
clearpart --all --initlabel
autopart --type=plain --nohome
bootloader --timeout=1
poweroff
%packages --exclude-weakdeps
@core
%end
%post
echo 'admin ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/admin && chmod 440 /etc/sudoers.d/admin
%end
EOF
  )
  genisoimage -quiet -o "$DIR/oemdrv.iso" -V OEMDRV -J -r "$DIR/ks"; rm -rf "$DIR/ks"
  qemu-img create -q -f qcow2 "$DIR/disk.qcow2" "$DISK"
  local cds="<disk type='file' device='cdrom'><driver name='qemu' type='raw'/><source file='$IMAGE'/><target dev='sda' bus='sata'/><readonly/></disk>
    <disk type='file' device='cdrom'><driver name='qemu' type='raw'/><source file='$DIR/oemdrv.iso'/><target dev='sdb' bus='sata'/><readonly/></disk>"
  domain_xml "<kernel>$DIR/vmlinuz</kernel><initrd>$DIR/initrd.img</initrd><cmdline>inst.stage2=hd:LABEL=$lesc inst.ks=hd:LABEL=OEMDRV:/ks.cfg inst.text console=ttyS0</cmdline>" "$cds" > "$DIR/install.xml"
  virsh create "$DIR/install.xml" >/dev/null       # transient: gone after the installer powers off
  local t=0; while virsh domstate "$NAME" >/dev/null 2>&1; do sleep 15; t=$((t+15)); [ $t -lt 3600 ] || die "installer did not finish within an hour (virsh console $NAME)"; done
  rm -f "$DIR/oemdrv.iso" "$DIR/vmlinuz" "$DIR/initrd.img" "$DIR/install.xml"
  domain_xml "" "" > "$DIR/domain.xml"
  virsh define "$DIR/domain.xml" >/dev/null && virsh start "$NAME" >/dev/null
}

# ---------- helpers for talking to the VM ----------
load_port() { PORT=$(cat "$DIR/port"); SSH=(ssh -i "$KEYF" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KH" -p "$PORT"); }
vm()   { "${SSH[@]}" admin@127.0.0.1 "$@"; }
vmsh() { "${SSH[@]}" admin@127.0.0.1 "sudo bash -s $(printf '%q ' "$@")"; }   # run a root script from stdin, args quoted
wait_vm() {
  for _ in $(seq 1 180); do vm 'systemctl is-system-running --wait >/dev/null 2>&1; echo READY' 2>/dev/null | grep -q READY && return 0; sleep 5; done
  die "VM did not come up (virsh console $NAME)"
}
reboot_vm() { vm 'sudo systemctl reboot' >/dev/null 2>&1 || true; sleep 20; wait_vm; }

base_setup() {
  log "Preparing the VM (updates, display support, automatic updates)"
  if [ "$OS" = rhel ]; then
    [ -n "$RHSM" ] || die "RHEL needs --rhsm FILE for registration and updates"
    { printf 'o=%q\nk=%q\n' "$(sed -n 's/^org=//p' "$RHSM")" "$(sed -n 's/^key=//p' "$RHSM")"
      # shellcheck disable=SC2016  # expanded by the guest's shell, from the o= and k= lines above
      echo 'subscription-manager status >/dev/null 2>&1 || subscription-manager register --org "$o" --activationkey "$k" >/dev/null'; } | vmsh
  fi
  local auto_pkg=dnf5-plugin-automatic auto_timer=dnf5-automatic.timer
  [ "$OS" = rhel ] && auto_pkg=dnf-automatic auto_timer=dnf-automatic.timer
  vmsh "$auto_pkg" "$auto_timer" "$(cat "$KEYF.pub")" <<'EOF'
set -e
grep -q '^install_weak_deps' /etc/dnf/dnf.conf || echo 'install_weak_deps=False' >> /etc/dnf/dnf.conf
dnf -y -q upgrade
dnf -y -q install waypipe google-noto-sans-fonts mesa-libEGL mesa-dri-drivers glibc-langpack-en "$1"
printf '[commands]\nupgrade_type = default\ndownload_updates = yes\napply_updates = yes\nreboot = when-needed\n' > /etc/dnf/automatic.conf
systemctl enable "$2" >/dev/null
id browser >/dev/null 2>&1 || useradd -c 'Browser (no admin rights)' browser
install -d -m 700 -o browser -g browser /home/browser/.ssh
echo "$3" > /home/browser/.ssh/authorized_keys
chown browser: /home/browser/.ssh/authorized_keys; chmod 600 /home/browser/.ssh/authorized_keys
restorecon -R /home/browser 2>/dev/null || true
touch /var/lib/vm-browser-base
EOF
  reboot_vm
}

# ---------- browsers ----------
prisma_prereqs() {
  vmsh <<'EOF'
set -e
grep -qw bpf /sys/kernel/security/lsm || { echo "kernel lacks the bpf LSM; Prisma's installer would rewrite boot settings without SELinux. Not installing."; exit 1; }
dnf -y -q install python3-bcc bcc clang "kernel-devel-$(uname -r)"
EOF
}

install_browser() {
  local b=$1
  log "Installing $b"
  case "$b" in
    chrome) vmsh <<'EOF'
set -e
printf '[google-chrome]\nname=google-chrome\nbaseurl=https://dl.google.com/linux/chrome/rpm/stable/x86_64\nenabled=1\ngpgcheck=1\ngpgkey=https://dl.google.com/linux/linux_signing_key.pub\n' > /etc/yum.repos.d/google-chrome.repo
dnf -y -q install google-chrome-stable
EOF
      PKG=google-chrome-stable;;
    brave) vmsh <<'EOF'
set -e
curl -fsSL -o /etc/yum.repos.d/brave-browser.repo https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo
dnf -y -q install brave-browser
EOF
      PKG=brave-browser;;
    firefox) vmsh <<< 'dnf -y -q install firefox'; PKG=firefox;;
    chromium)
      if [ "$OS" = rhel ]; then vmsh "$VER" <<'EOF'
set -e
subscription-manager repos --enable "codeready-builder-for-rhel-$1-x86_64-rpms" >/dev/null
rpm -q epel-release >/dev/null || dnf -y -q install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$1.noarch.rpm"
dnf -y -q install chromium
EOF
      else vmsh <<< 'dnf -y -q install chromium'; fi
      PKG=chromium;;
    prisma) prisma_prereqs; vmsh <<'EOF'
set -e
printf '[prisma-access-browser]\nname=Prisma Access Browser\nbaseurl=https://updates.talon-sec.com/linux/prisma-access-browser/rpm/stable/x86_64\ngpgcheck=1\ngpgkey=https://updates.talon-sec.com/linux/prisma-access-browser/linux_signing_key.pub\n' > /etc/yum.repos.d/prisma-access-browser.repo
dnf -y -q install prisma-access-browser-stable
systemctl restart pab-protection
EOF
      PKG=prisma-access-browser-stable;;
  esac
  make_launcher "$PKG"
}

install_rpm() {
  local f=$1 pkg
  pkg=$(rpm -qp --qf '%{NAME}' "$f" 2>/dev/null) || die "not an RPM: $f"
  log "Installing $pkg from $(basename "$f")"
  [ "$pkg" = prisma-access-browser-stable ] && prisma_prereqs
  scp -q -i "$KEYF" -o IdentitiesOnly=yes -o UserKnownHostsFile="$KH" -P "$PORT" "$f" admin@127.0.0.1:/var/tmp/vm-browser.rpm
  vmsh <<'EOF'
set -e
dnf -y -q install /var/tmp/vm-browser.rpm; rm -f /var/tmp/vm-browser.rpm
systemctl list-unit-files pab-protection.service >/dev/null 2>&1 && systemctl restart pab-protection || true
EOF
  make_launcher "$pkg"
}

# Builds the launcher from the package's own .desktop file: name, command, icon, window class.
make_launcher() {
  local pkg=$1 info name exe icon wm id ext
  info=$(vmsh "$pkg" <<'EOF'
d=$(rpm -ql "$1" | grep -E '^/usr/share/applications/[^/]+\.desktop$' | head -1)
[ -n "$d" ] || { echo "no desktop file in $1" >&2; exit 1; }
get() { sed -n "0,/^\[Desktop Entry\]/d; /^\[/q; s/^$1=//p" "$d" | head -1; }
icon=$(get Icon)
case "$icon" in
  /*) p=$icon;;
  *) p=$(ls /usr/share/icons/hicolor/{256x256,512x512,192x192,128x128,scalable,96x96,64x64,48x48}/apps/"$icon".{png,svg} /usr/share/pixmaps/"$icon".{png,svg} 2>/dev/null | head -1);;
esac
exe=$(get Exec | awk '{print $1}')
wm=$(get StartupWMClass)
echo "$(get Name)"; echo "$exe"; echo "$p"; echo "${wm:-$(basename "$exe")}"
EOF
)
  { read -r name; read -r exe; read -r icon; read -r wm; } <<< "$info"
  [ -n "$exe" ] || die "could not find how to start $pkg"
  id="vmb-$NAME-$pkg"
  if [ -n "$icon" ]; then
    local dest; ext=${icon##*.}; dest="$HOME/.local/share/icons/hicolor/$([ "$ext" = svg ] && echo scalable || echo 256x256)/apps"
    mkdir -p "$dest"; scp -q -i "$KEYF" -o IdentitiesOnly=yes -o UserKnownHostsFile="$KH" -P "$PORT" "admin@127.0.0.1:$icon" "$dest/$id.$ext"
  fi
  mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
  cat > "$HOME/.local/bin/$id" <<EOF
#!/bin/bash
# vm-browser launcher: $name in VM $NAME
export LIBVIRT_DEFAULT_URI=qemu:///session
SSH=(ssh -i "$KEYF" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=3 -o UserKnownHostsFile="$KH" -p $PORT browser@127.0.0.1)
[ "\$(virsh domstate $NAME 2>/dev/null)" = running ] || virsh start $NAME >/dev/null
for _ in \$(seq 1 60); do "\${SSH[@]}" true 2>/dev/null && break; sleep 2; done
exec waypipe --no-gpu "\${SSH[@]}" $exe "\$@"
EOF
  chmod 755 "$HOME/.local/bin/$id"
  cat > "$HOME/.local/share/applications/$id.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$name ($NAME)
Comment=Runs in the isolated VM $NAME
Exec=$HOME/.local/bin/$id
Icon=$id
Terminal=false
Categories=Network;WebBrowser;
StartupWMClass=$wm
EOF
  gtk-update-icon-cache -q -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
  echo "Launcher: '$name ($NAME)' in your app menu ($HOME/.local/bin/$id)"
}

# ---------- main ----------
main() {
  parse_args "$@"
  setup
  if ! virsh dominfo "$NAME" >/dev/null 2>&1; then
    [ ! -f "$DIR/disk.qcow2" ] || die "$DIR has a disk but no VM; remove that folder first"
    create_vm
  fi
  [ "$(virsh domstate "$NAME")" = running ] || virsh start "$NAME" >/dev/null
  load_port; wait_vm
  vm 'test -f /var/lib/vm-browser-base' 2>/dev/null || base_setup
  for b in "${BROWSERS[@]}"; do install_browser "$b"; done
  for r in "${RPMS[@]}"; do install_rpm "$r"; done
  log "Done. VM $NAME: $(vm 'df -h / | tail -1' | awk '{print $3" used of "$2}'); disk file $(du -h "$DIR/disk.qcow2" | cut -f1)"
}

# Run only when executed, not when sourced (tests/run.sh sources it to test single functions).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
