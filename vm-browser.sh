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
  --lan                Let the VM reach your local network (default: blocked;
                       the desktop's own services stay blocked either way)
  -h, --help
EOF
}

OS=fedora VER="" IMAGE="" RHSM="" NAME="" PORT="" MEM=4 CPUS=4 DISK=12G LAN=0
BROWSERS=() RPMS=()
parse_args() {
while [ $# -gt 0 ]; do
  case "$1" in
    --os) OS=$2; shift 2;; --version) VER=$2; shift 2;; --image) IMAGE=$(realpath "$2"); shift 2;;
    --rhsm) RHSM=$(realpath "$2"); shift 2;; --rpm) RPMS+=("$(realpath "$2")"); shift 2;;
    --name) NAME=$2; shift 2;; --port) PORT=$2; shift 2;; --memory) MEM=$2; shift 2;;
    --cpus) CPUS=$2; shift 2;; --disk) DISK=$2; shift 2;; --lan) LAN=1; shift;; -h|--help) usage; exit 0;;
    chrome|chromium|brave|firefox|prisma) BROWSERS+=("$1"); shift;;
    *) echo "Unknown argument: $1"; usage; exit 1;;
  esac
done
case "$OS" in fedora) VER=${VER:-44};; rhel) VER=${VER:-10};; *) echo "--os must be fedora or rhel"; exit 1;; esac
NAME=${NAME:-$OS$VER-browsers}
[ ${#BROWSERS[@]} -gt 0 ] || [ ${#RPMS[@]} -gt 0 ] || { echo "Choose at least one browser or --rpm."; usage; exit 1; }
check_options
}

# The options go into file paths, the domain XML, cloud-init and kickstart files: plain values only.
check_options() {
  [[ $NAME =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] || die "--name: letters, digits and hyphens, at most 63, starting with a letter or digit"
  [[ $VER =~ ^[0-9]{1,3}$ ]] || die "--version: a release number such as 44 or 10"
  [ -z "$PORT" ] || { [[ $PORT =~ ^[0-9]{4,5}$ ]] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ]; } || die "--port: a number from 1024 to 65535"
  [[ $MEM =~ ^[1-9][0-9]{0,2}$ ]] || die "--memory: whole GiB, such as 4"
  [[ $CPUS =~ ^[1-9][0-9]{0,2}$ ]] || die "--cpus: a number, such as 4"
  [[ $DISK =~ ^[1-9][0-9]{0,4}[MGT]?$ ]] || die "--disk: a size such as 12G"
}

log() { printf '\n== %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# State folder, keys and host tools. Separate from parse_args so the tests can source this file.
setup() {
  export LIBVIRT_DEFAULT_URI=qemu:///session
  DIR="$HOME/.local/share/vm-browser/$NAME"
  mkdir -p "$DIR"; chmod 700 "$DIR"
  # Separate keys for the admin account (sudo) and the browser account the launchers use, and
  # the VM's own SSH host key, made here so known_hosts is pinned before the VM first boots.
  KEYF="$DIR/id_ed25519"; BKEYF="$DIR/browser_ed25519"; HKEYF="$DIR/ssh_host_ed25519_key"; KH="$DIR/known_hosts"
  for c in virsh qemu-img passt waypipe genisoimage isoinfo ssh scp curl gpgv gpg; do
    command -v "$c" >/dev/null || die "missing $c. Install: sudo dnf install libvirt-client libvirt-daemon-kvm qemu-kvm qemu-img passt waypipe genisoimage openssh-clients curl gnupg2"
  done
}

# ---------- VM creation (skipped if the VM already exists) ----------
create_vm() {
  [ -f "$KEYF" ] || ssh-keygen -q -t ed25519 -N '' -C "vm-browser-$NAME-admin" -f "$KEYF"
  [ -f "$BKEYF" ] || ssh-keygen -q -t ed25519 -N '' -C "vm-browser-$NAME-browser" -f "$BKEYF"
  rm -f "$HKEYF" "$HKEYF.pub"; ssh-keygen -q -t ed25519 -N '' -C "$NAME" -f "$HKEYF"
  local key; key=$(cat "$KEYF.pub")
  if [ -z "$PORT" ]; then   # first port that is neither listening nor assigned to another vm-browser VM
    PORT=2230; while ss -Htln "sport = :$PORT" | grep -q . || cat "$HOME"/.local/share/vm-browser/*/port 2>/dev/null | grep -qx "$PORT"; do PORT=$((PORT+1)); done
  fi
  echo "$PORT" > "$DIR/port"
  # Only this host key is accepted on the port, so a listener another local user starts there
  # first gets no commands and no credentials.
  printf '[127.0.0.1]:%s %s\n' "$PORT" "$(cut -d' ' -f1,2 "$HKEYF.pub")" > "$KH"

  if [ -z "$IMAGE" ]; then
    [ "$OS" = fedora ] || die "RHEL images need a Red Hat login. Download the KVM guest image or DVD ISO from access.redhat.com and pass --image."
    fetch_fedora_cloud
  fi
  case "$IMAGE" in
    *.iso) install_from_iso "$key";;
    *.qcow2|*.img) install_from_cloud_image "$key";;
    *) die "--image must be a .qcow2 or .iso";;
  esac
  rm -f "$HKEYF"   # the VM has it now
}

# Fedora release keys: the primary key fingerprint per release. A Fedora image is used only if
# its CHECKSUM file is signed by the key pinned here for that release. Taken from the
# fedora-gpg-keys package (verified by rpm) and checked against https://fedoraproject.org/security/.
# Add each new release here.
declare -A FEDORA_KEYS=(
  [42]=B0F4950458F69E1150C6C5EDC8AC4916105EF944
  [43]=C6E7F081CF80E13146676E88829B606631645531
  [44]=36F612DCF27F7D1A48A835E4DBFCF71C6D9F90A6
  [45]=4F50A6114CD5C6976A7F1179655A4B02F577861E
  [46]=D924B10D3E810DABDD8B56B596E7E91491211FCE
  [47]=B2E766FA50CA6FA2D5ED06FC09D879E09488FB64
)

# verify_signed FILE KEYRING FINGERPRINT: prints only the signed text of the clearsigned FILE,
# and only if it carries a good signature by the key with FINGERPRINT (primary key). gpgv
# accepts unsigned text around the signed block, so nothing outside the block may be trusted.
verify_signed() {
  local f=$1 keyring fpr=$3 tmp status
  keyring=$(realpath "$2")   # gpgv looks for a bare name in ~/.gnupg
  tmp=$(mktemp -d)
  if ! status=$(gpgv --status-fd 1 --keyring "$keyring" --output "$tmp/signed" "$f" 2>"$tmp/err"); then
    cat "$tmp/err" >&2; rm -rf "$tmp"; return 1
  fi
  # VALIDSIG <signing key> ... <primary key>: the last field is the primary key's fingerprint.
  if ! grep -Eq "^\[GNUPG:\] VALIDSIG [0-9A-F]+ .* $fpr\$" <<< "$status"; then
    echo "signature is good but not by the expected key $fpr" >&2; rm -rf "$tmp"; return 1
  fi
  cat "$tmp/signed"; rm -rf "$tmp"
}

# fedora_cloud_entry VERSION < CHECKSUM text: prints "IMAGE SHA256" for the Cloud Base Generic image.
fedora_cloud_entry() {
  sed -nE "s/^SHA256 \((Fedora-Cloud-Base-Generic-$1-[0-9.]+\.x86_64\.qcow2)\) = ([0-9a-f]{64})\$/\1 \2/p" | head -1
}

fetch_fedora_cloud() {
  local base="https://dl.fedoraproject.org/pub/fedora/linux/releases/$VER/Cloud/x86_64/images"
  local fpr=${FEDORA_KEYS[$VER]:-}
  [ -n "$fpr" ] || die "no pinned signing key for Fedora $VER in this script. Pass --image with an image you have verified, or add the release's key to FEDORA_KEYS."
  log "Finding the Fedora $VER Cloud image"
  local sumf; sumf=$(curl -fsSL "$base/" | grep -oE "Fedora-Cloud-$VER-[0-9.]+-x86_64-CHECKSUM" | sort -uV | tail -1)
  [ -n "$sumf" ] || die "no Fedora $VER Cloud image found at $base"
  curl -fsSL -o "$DIR/CHECKSUM" "$base/$sumf"
  # Any keyring will do: only a signature by the pinned fingerprint is accepted.
  curl -fsSL https://fedoraproject.org/fedora.gpg | gpg --dearmor > "$DIR/fedora.gpg"
  local entry img sum
  entry=$(verify_signed "$DIR/CHECKSUM" "$DIR/fedora.gpg" "$fpr" | fedora_cloud_entry "$VER") || true
  [ -n "$entry" ] || die "CHECKSUM ($sumf) is not signed by the Fedora $VER key $fpr, or lists no Cloud image"
  read -r img sum <<< "$entry"
  log "Downloading $img"
  curl -fL -o "$DIR/$img" "https://download.fedoraproject.org/pub/fedora/linux/releases/$VER/Cloud/x86_64/images/$img"
  [ "$(sha256sum < "$DIR/$img" | cut -d' ' -f1)" = "$sum" ] || { rm -f "$DIR/$img"; die "image checksum mismatch: $img"; }
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
  ( umask 077; cat > "$DIR/user-data" <<EOF
#cloud-config
hostname: $NAME
ssh_pwauth: false
users:
  - name: admin
    groups: [wheel]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys: ["$1"]
ssh_keys:
  ed25519_private: |
$(sed 's/^/    /' "$HKEYF")
  ed25519_public: $(cut -d' ' -f1,2 "$HKEYF.pub")
EOF
  )
  printf 'instance-id: %s\nlocal-hostname: %s\n' "$NAME" "$NAME" > "$DIR/meta-data"
  ( umask 077; genisoimage -quiet -o "$DIR/seed.iso" -V cidata -J -r "$DIR/user-data" "$DIR/meta-data" )
  rm -f "$DIR/user-data"   # it holds the host key; the seed disc keeps a copy for cloud-init
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
  elif [ "$OS" = fedora ]; then
    # A metalink, not a mirrorlist: it comes over TLS from Fedora and carries the hash of the
    # repository metadata, which in turn hashes every package, so a mirror can't swap packages.
    src="url --metalink=https://mirrors.fedoraproject.org/metalink?repo=fedora-$VER&arch=x86_64"
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
umask 077
cat > /etc/ssh/ssh_host_ed25519_key <<'KEY'
$(cat "$HKEYF")
KEY
echo '$(cut -d' ' -f1,2 "$HKEYF.pub")' > /etc/ssh/ssh_host_ed25519_key.pub
chmod 644 /etc/ssh/ssh_host_ed25519_key.pub; restorecon /etc/ssh/ssh_host_ed25519_key*
%end
EOF
  )
  # The install files hold the host key and, for boot ISOs, the activation key: removed however
  # the install ends.
  trap 'virsh destroy "$NAME" >/dev/null 2>&1; rm -rf "$DIR/ks" "$DIR/oemdrv.iso" "$DIR/vmlinuz" "$DIR/initrd.img" "$DIR/install.xml"' EXIT
  ( umask 077; genisoimage -quiet -o "$DIR/oemdrv.iso" -V OEMDRV -J -r "$DIR/ks" ); rm -rf "$DIR/ks"
  qemu-img create -q -f qcow2 "$DIR/disk.qcow2" "$DISK"
  local cds="<disk type='file' device='cdrom'><driver name='qemu' type='raw'/><source file='$IMAGE'/><target dev='sda' bus='sata'/><readonly/></disk>
    <disk type='file' device='cdrom'><driver name='qemu' type='raw'/><source file='$DIR/oemdrv.iso'/><target dev='sdb' bus='sata'/><readonly/></disk>"
  domain_xml "<kernel>$DIR/vmlinuz</kernel><initrd>$DIR/initrd.img</initrd><cmdline>inst.stage2=hd:LABEL=$lesc inst.ks=hd:LABEL=OEMDRV:/ks.cfg inst.text console=ttyS0</cmdline>" "$cds" > "$DIR/install.xml"
  virsh create "$DIR/install.xml" >/dev/null       # transient: gone after the installer powers off
  local t=0; while virsh domstate "$NAME" >/dev/null 2>&1; do sleep 15; t=$((t+15)); [ $t -lt 3600 ] || die "installer did not finish within an hour (virsh console $NAME)"; done
  rm -f "$DIR/oemdrv.iso" "$DIR/vmlinuz" "$DIR/initrd.img" "$DIR/install.xml"; trap - EXIT
  domain_xml "" "" > "$DIR/domain.xml"
  virsh define "$DIR/domain.xml" >/dev/null && virsh start "$NAME" >/dev/null
}

# ---------- helpers for talking to the VM ----------
# Every ssh and scp to the VM uses -F none: the desktop's ~/.ssh/config and ssh_config.d are not
# read, so a "Host *" block there can't forward the SSH agent or X11, or add a ProxyCommand.
# The VM's host key is pinned in known_hosts when it is created: StrictHostKeyChecking=yes.
SSHOPT=(-F none -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o HostKeyAlgorithms=ssh-ed25519)
load_port() { PORT=$(cat "$DIR/port"); SSH=(ssh "${SSHOPT[@]}" -i "$KEYF" -o ConnectTimeout=5 -o UserKnownHostsFile="$KH" -p "$PORT"); }
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
      echo 'subscription-manager status >/dev/null 2>&1 || subscription-manager register --org "$o" --activationkey "$k" >/dev/null'
      # A boot ISO install had the key in its kickstart: Anaconda keeps copies of that and logs.
      # shellcheck disable=SC2016  # expanded by the guest's shell
      echo 'grep -rlsF -- "$k" /root /var/log/anaconda /var/log/anaconda.* 2>/dev/null | xargs -r shred -u'; } | vmsh
  fi
  local auto_pkg=dnf5-plugin-automatic auto_timer=dnf5-automatic.timer
  [ "$OS" = rhel ] && auto_pkg=dnf-automatic auto_timer=dnf-automatic.timer
  vmsh "$auto_pkg" "$auto_timer" "$(cat "$BKEYF.pub")" <<'EOF'
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

# VMs made by older versions let the launchers in with the admin key: give the browser account
# its own key, and rewrite their launchers below as browsers are (re)installed.
ensure_browser_key() {
  [ -f "$BKEYF" ] && [ -f "$DIR/browser-key-installed" ] && return 0
  [ -f "$BKEYF" ] || ssh-keygen -q -t ed25519 -N '' -C "vm-browser-$NAME-browser" -f "$BKEYF"
  vmsh "$(cat "$BKEYF.pub")" <<'EOF'
set -e
printf '%s\n' "$1" > /home/browser/.ssh/authorized_keys
chown browser: /home/browser/.ssh/authorized_keys; chmod 600 /home/browser/.ssh/authorized_keys
restorecon -R /home/browser/.ssh 2>/dev/null || true
EOF
  : > "$DIR/browser-key-installed"
}

# ---------- network guard ----------
# passt hands the guest's traffic for the gateway address to the desktop's 127.0.0.1, so
# without this the browser could reach every loopback-only service on the desktop (CUPS,
# keyboard sharing, other VMs' SSH ports, dev servers). An nftables table in the guest drops
# that, and by default the private and link-local networks too (the LAN), leaving DNS, DHCP
# and the internet. It runs at every boot, after the network is up, from the gateway the guest
# has then. Root in the guest could remove it; the browser runs without root.
# --lan keeps the LAN reachable (the gateway stays blocked).
setup_netguard() {
  log "Network guard (desktop loopback blocked; LAN $([ "$LAN" = 1 ] && echo allowed || echo blocked))"
  vmsh "$LAN" <<'EOF'
set -e
rpm -q nftables >/dev/null 2>&1 || dnf -y -q install nftables
install -d /etc/vm-browser
echo "ALLOW_LAN=$1" > /etc/vm-browser/netguard.conf
cat > /usr/local/sbin/vm-browser-netguard <<'GUARD'
#!/bin/bash
# vm-browser: drop the guest's traffic to the gateway (passt maps it to the desktop's
# loopback) and, unless ALLOW_LAN=1, to private and link-local networks. DNS and DHCP pass.
set -euo pipefail
ALLOW_LAN=0; . /etc/vm-browser/netguard.conf
gw4=$(ip -4 route show default | awk '{print $3; exit}')
gw6=$(ip -6 route show default | awk '{print $3; exit}')
{
  echo 'table inet vm_browser'; echo 'delete table inet vm_browser'
  echo 'table inet vm_browser {'
  echo ' chain out {'
  echo '  type filter hook output priority 0; policy accept;'
  echo '  ct state established,related accept'
  echo '  oif "lo" accept'
  echo '  meta l4proto { udp, tcp } th dport 53 accept'
  echo '  meta l4proto udp udp dport { 67, 547 } accept'
  echo '  meta l4proto ipv6-icmp accept'
  [ -z "$gw4" ] || echo "  ip daddr $gw4 counter reject"
  [ -z "$gw6" ] || echo "  ip6 daddr $gw6 counter reject"
  if [ "$ALLOW_LAN" != 1 ]; then
    echo '  ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10 } counter reject'
    echo '  ip6 daddr { fc00::/7, fe80::/10 } counter reject'
  fi
  echo ' }'
  echo '}'
} | nft -f -
GUARD
chmod 755 /usr/local/sbin/vm-browser-netguard
cat > /etc/systemd/system/vm-browser-netguard.service <<'UNIT'
[Unit]
Description=vm-browser: block the desktop's loopback and the LAN
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/vm-browser-netguard

[Install]
WantedBy=multi-user.target
UNIT
restorecon /usr/local/sbin/vm-browser-netguard /etc/systemd/system/vm-browser-netguard.service 2>/dev/null || true
systemctl daemon-reload
systemctl enable vm-browser-netguard.service >/dev/null 2>&1
systemctl restart vm-browser-netguard.service
nft list table inet vm_browser >/dev/null
EOF
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
  safe_word "$pkg" || die "refusing package name $(printf '%q' "$pkg") in $f"
  log "Installing $pkg from $(basename "$f")"
  [ "$pkg" = prisma-access-browser-stable ] && prisma_prereqs
  scp -q "${SSHOPT[@]}" -i "$KEYF" -o UserKnownHostsFile="$KH" -P "$PORT" "$f" admin@127.0.0.1:/var/tmp/vm-browser.rpm
  vmsh <<'EOF'
set -e
dnf -y -q install /var/tmp/vm-browser.rpm; rm -f /var/tmp/vm-browser.rpm
systemctl list-unit-files pab-protection.service >/dev/null 2>&1 && systemctl restart pab-protection || true
EOF
  make_launcher "$pkg"
}

# ---------- launchers ----------
# Everything the VM reports is untrusted: a malicious --rpm, a compromised repository or an
# already compromised VM chooses it. It is validated here before it reaches a file or a
# command on the desktop.

# clean_text: one line of printable text, at most 80 characters, for names shown on the desktop.
clean_text() { LC_ALL=C tr -d '\000-\037\177' | head -c 80; }
# safe_path / safe_word STRING: true if STRING is a plain command path, or a plain window class
# or package name: no spaces, quotes or shell characters.
safe_path() { [[ $1 =~ ^/?[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*$ && $1 != *..* && ${#1} -le 200 ]]; }
safe_word() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && ${#1} -le 100 ]]; }
# desktop_quote STRING: STRING as one argument of a .desktop Exec key (spec: double quotes,
# with \ " ` $ escaped by a backslash).
desktop_quote() { local q=${1//\\/\\\\}; q=${q//\"/\\\"}; q=${q//\`/\\\`}; q=${q//\$/\\\$}; printf '"%s"' "$q"; }

# write_launcher PKG NAME EXE ICON-FILE WM: writes the launcher script and the menu entry from
# validated values. EXE is refused unless it is a plain path; NAME is cleaned; WM falls back to
# EXE's file name.
write_launcher() {
  local pkg=$1 name exe=$3 iconf=$4 wm=$5 id bin
  name=$(printf '%s' "$2" | clean_text); [ -n "$name" ] || name=$pkg
  safe_path "$exe" || die "refusing the start command the VM reported for $pkg: $(printf '%q' "$exe")"
  safe_word "$wm" || wm=$(basename "$exe")
  id="vmb-$NAME-$pkg"; bin="$HOME/.local/bin/$id"
  mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
  # The values go in as shell-quoted assignments; the rest of the script is fixed text.
  {
    echo '#!/bin/bash'
    echo "# vm-browser launcher. Generated; rerun vm-browser.sh to change it."
    printf 'VM=%q KEY=%q KH=%q PORT=%q EXE=%q\n' "$NAME" "$BKEYF" "$KH" "$PORT" "$exe"
    cat <<'LAUNCHER'
export LIBVIRT_DEFAULT_URI=qemu:///session
SSH=(ssh -F none -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o HostKeyAlgorithms=ssh-ed25519 -o ConnectTimeout=3 -o UserKnownHostsFile="$KH" -p "$PORT" browser@127.0.0.1)
# One session file per open launcher, so the VM can be stopped when the last one closes.
RUN="${XDG_RUNTIME_DIR:-/tmp/vm-browser-$(id -u)}/vm-browser-$VM"; mkdir -p -m 700 "$RUN"
exec 9>"$RUN/lock"
flock 9; touch "$RUN/session.$$"
[ "$(virsh domstate "$VM" 2>/dev/null)" = running ] || virsh start "$VM" >/dev/null
flock -u 9
for _ in $(seq 1 60); do
  "${SSH[@]}" true 2>/dev/null && break
  # A VM that was still shutting down when this launcher started: start it again.
  [ "$(virsh domstate "$VM" 2>/dev/null)" != "shut off" ] || virsh start "$VM" >/dev/null 2>&1
  sleep 2
done
# ssh joins its arguments into one command line for the VM's shell: quote each one (URLs).
CMD="$EXE$(printf ' %q' "$@")"
# --secctx marks the VM's windows through the wp_security_context_v1 protocol, so compositors
# that support it (Sway, Hyprland, ...) can tell them apart and withhold privileged protocols.
# Compositors without it (GNOME) make waypipe stop at once: then run it without.
err=$(mktemp); trap 'rm -f "$err"' EXIT
waypipe --secctx "vm-browser.$VM" --no-gpu "${SSH[@]}" "$CMD" 2> >(tee "$err" >&2) 9>&-; rc=$?; wait $! 2>/dev/null
if [ $rc -ne 0 ] && grep -q wp_security_context_manager_v1 "$err"; then
  waypipe --no-gpu "${SSH[@]}" "$CMD" 9>&-; rc=$?
fi
# The last window closed: stop the VM, so it isn't running, online, while nothing uses it.
# An automatic update that is running in the VM finishes first. VMB_KEEP_RUNNING=1 skips this.
others() {   # true if another launcher of this VM is still open (session files of dead ones are removed)
  local f; for f in "$RUN"/session.*; do [ -e "$f" ] && ! kill -0 "${f##*.}" 2>/dev/null && rm -f "$f"; done
  compgen -G "$RUN/session.*" >/dev/null
}
flock 9; rm -f "$RUN/session.$$"; others; last=$?; flock -u 9
if [ $last -ne 0 ] && [ -z "${VMB_KEEP_RUNNING:-}" ]; then
  for _ in $(seq 1 120); do   # up to an hour
    "${SSH[@]}" 'systemctl is-active --quiet dnf5-automatic.service dnf-automatic.service' 2>/dev/null || break
    sleep 30
  done
  flock 9; others || virsh shutdown "$VM" >/dev/null 2>&1; flock -u 9
fi
exit $rc
LAUNCHER
  } > "$bin"
  chmod 755 "$bin"
  {
    echo '[Desktop Entry]'
    echo 'Type=Application'
    echo "Name=$name ($(printf '%s' "$NAME" | clean_text))"
    echo 'Comment=Runs in an isolated VM'
    echo "Exec=$(desktop_quote "$bin")"
    if [ -n "$iconf" ]; then echo "Icon=$id"; else echo 'Icon=web-browser'; fi
    echo 'Terminal=false'
    echo 'Categories=Network;WebBrowser;'
    echo "StartupWMClass=$wm"
  } > "$HOME/.local/share/applications/$id.desktop"
  echo "Launcher: '$name ($NAME)' in your app menu ($bin)"
}

# fetch_icon GUEST-PATH ID: copies a PNG icon from the VM to the desktop's icon folder as ID.png.
fetch_icon() {
  local tmp dest="$HOME/.local/share/icons/hicolor/256x256/apps"
  tmp=$(mktemp)
  if vm "head -c 524289 -- $(printf '%q' "$1")" > "$tmp" 2>/dev/null && [ "$(stat -c %s "$tmp")" -le 524288 ] \
     && [ "$(head -c 8 "$tmp" | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ]; then
    mkdir -p "$dest"; mv "$tmp" "$dest/$2.png"; chmod 644 "$dest/$2.png"
  else
    rm -f "$tmp"; return 1
  fi
}

# Builds the launcher from the package's own .desktop file: name, command, icon, window class.
make_launcher() {
  local pkg=$1 info name exe icon wm id
  safe_word "$pkg" || die "refusing package name $(printf '%q' "$pkg")"
  info=$(vmsh "$pkg" <<'EOF'
d=$(rpm -ql "$1" | grep -E '^/usr/share/applications/[^/]+\.desktop$' | head -1)
[ -n "$d" ] || { echo "no desktop file in $1" >&2; exit 1; }
get() { sed -n "0,/^\[Desktop Entry\]/d; /^\[/q; s/^$1=//p" "$d" | head -1; }
icon=$(get Icon)
case "$icon" in
  /*) p=$icon;;
  *) p=$(ls /usr/share/icons/hicolor/{256x256,512x512,192x192,128x128,96x96,64x64,48x48}/apps/"$icon".png /usr/share/pixmaps/"$icon".png 2>/dev/null | head -1);;
esac
exe=$(get Exec | awk '{print $1}')
wm=$(get StartupWMClass)
echo "$(get Name)"; echo "$exe"; echo "$p"; echo "${wm:-$(basename "$exe")}"
EOF
)
  { read -r name; read -r exe; read -r icon; read -r wm; } <<< "$info" || true   # $(...) drops empty last lines
  [ -n "$exe" ] || die "could not find how to start $pkg"
  id="vmb-$NAME-$pkg"
  # Icons are parsed by the desktop's image loaders, so only PNG files up to 512 KiB are taken
  # (no SVG), checked by their signature, under a file name chosen here.
  if [ -n "$icon" ] && safe_path "$icon" && [[ $icon == *.png ]] && fetch_icon "$icon" "$id"; then :; else icon=""; fi
  write_launcher "$pkg" "$name" "$exe" "$icon" "$wm"
  gtk-update-icon-cache -q -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
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
  ensure_browser_key
  setup_netguard
  for b in "${BROWSERS[@]}"; do install_browser "$b"; done
  for r in "${RPMS[@]}"; do install_rpm "$r"; done
  log "Done. VM $NAME: $(vm 'df -h / | tail -1' | awk '{print $3" used of "$2}' | clean_text); disk file $(du -h "$DIR/disk.qcow2" | cut -f1)"
}

# Run only when executed, not when sourced (tests/run.sh sources it to test single functions).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
