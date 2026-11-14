# shellcheck shell=bash disable=SC2016  # the checks are bash -c scripts, expanded when they run
# Files made for the VM and taken from it (#7): the cloud-init seed and icons.

check "cloud images: cloud-init gets the pinned host key, and the user-data file is removed" \
  bash -c '
    source ./vm-browser.sh
    OS=fedora VER=44 NAME=ci-test DIR=$T/ci-dir MEM=4 CPUS=4 DISK=12G PORT=2299 IMAGE=$T/img.qcow2 DOWNLOADED=0
    rm -rf "$DIR"; mkdir -p "$DIR"; : > "$IMAGE"; HKEYF=$DIR/hostkey; ssh-keygen -q -t ed25519 -N "" -C test -f "$HKEYF"
    qemu-img() { :; }; virsh() { :; }
    genisoimage() { cp "$DIR/user-data" "$T/ud-out"; local o; while [ $# -gt 0 ]; do [ "$1" = -o ] && o=$2; shift; done; : > "$o"; }
    install_from_cloud_image "ssh-ed25519 AAAATEST admin" >/dev/null
    grep -q "^  ed25519_private: |$" "$T/ud-out" && grep -q "^    -----BEGIN OPENSSH PRIVATE KEY-----$" "$T/ud-out" \
      && grep -qx "  ed25519_public: $(cut -d" " -f1,2 "$HKEYF.pub")" "$T/ud-out" && [ ! -e "$DIR/user-data" ]'

# fetch_icon with a stubbed VM that serves local files.
icon_ok() {
  rm -rf "$T/ih"; mkdir -p "$T/ih"
  HOME=$T/ih bash -c 'source ./vm-browser.sh; vm() { eval "$1"; }; fetch_icon "$1" testicon && [ -s "$HOME/.local/share/icons/hicolor/256x256/apps/testicon.png" ]' _ "$1"
}
export -f icon_ok
printf '\x89PNG\r\n\x1a\nrest-of-a-png' > "$T/good.png"
printf '<svg xmlns="http://www.w3.org/2000/svg"/>' > "$T/fake.png"
{ printf '\x89PNG\r\n\x1a\n'; head -c 600000 /dev/zero; } > "$T/huge.png"
check "a PNG icon is copied" icon_ok "$T/good.png"
fails "a file named .png that isn't a PNG (an SVG) is refused" icon_ok "$T/fake.png"
fails "a PNG over 512 KiB is refused" icon_ok "$T/huge.png"
fails "a missing icon is refused" icon_ok "$T/none.png"

# install_rpm with a stubbed VM: records where the RPM is copied and what root installs.
rpm_install() {
  bash -c '
    source ./vm-browser.sh
    KEYF=$T/k KH=$T/kh PORT=2299 NAME=t
    rpm() { echo testbrowser; }; prisma_prereqs() { :; }; make_launcher() { :; }
    vm() { echo "${VM_TMP:-/var/tmp/vm-browser.Ab12}"; }
    scp() { printf "%s\n" "${@: -1}" > "$T/rpm-scp"; }
    vmsh() { printf "%s\n" "$@" > "$T/rpm-args"; cat > "$T/rpm-script"; }
    install_rpm "$T/x.rpm"'
}
export -f rpm_install
check "an --rpm is copied into a private folder made in the VM, not a fixed path (#7)" \
  bash -c 'rpm_install >/dev/null && grep -qx admin@127.0.0.1:/var/tmp/vm-browser.Ab12/browser.rpm "$T/rpm-scp" && grep -qx /var/tmp/vm-browser.Ab12 "$T/rpm-args" && grep -q "admin 700" "$T/rpm-script" && ! grep -q vm-browser.rpm vm-browser.sh'
fails "a folder name from the VM with shell characters is refused" \
  bash -c 'VM_TMP="/tmp/x;id" rpm_install'
