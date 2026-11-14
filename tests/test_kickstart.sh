# shellcheck shell=bash disable=SC2016  # the checks are bash -c scripts, expanded when they run
# The kickstart written for installer ISOs (install_from_iso), checked without running an
# install: virsh, isoinfo and genisoimage are replaced by stubs that record what they get.

# ks_for OS VER ISO-KIND [RHSM-FILE]: writes the kickstart vm-browser would use to $T/ks-out.
# ISO-KIND "dvd" has packages on the disc, "net" has none.
ks_for() {
  bash -c '
    source ./vm-browser.sh
    KIND=$3 OS=$1 VER=$2 NAME=ks-test DIR=$T/ks-dir RHSM=${4:-} MEM=4 CPUS=4 DISK=12G PORT=2299 IMAGE=$T/fake.iso
    rm -rf "$DIR"; mkdir -p "$DIR"; HKEYF=$DIR/hostkey; ssh-keygen -q -t ed25519 -N "" -C test -f "$HKEYF"
    isoinfo() { case "$*" in *-d*) echo "Volume id: Test-Label";; *-x*) echo kernel;; *-f*) [ "$KIND" = dvd ] && echo /BaseOS/repodata;; esac; }
    genisoimage() { local o; while [ $# -gt 0 ]; do case $1 in -o) o=$2; shift;; esac; shift; done; cp "$DIR/ks/ks.cfg" "$T/ks-out"; : > "$o"; }
    virsh() { [ "$1" != domstate ] || [ -n "${HANG:-}" ]; }; qemu-img() { :; }; sleep() { :; }
    install_from_iso "ssh-ed25519 AAAATEST test" >/dev/null
  ' _ "$@"
}
export -f ks_for

check "Fedora netinstall: packages come through a metalink, not a mirrorlist" \
  bash -c 'ks_for fedora 45 net && grep -qx "url --metalink=https://mirrors.fedoraproject.org/metalink?repo=fedora-45&arch=x86_64" "$T/ks-out" && ! grep -q mirrorlist "$T/ks-out"'
check "Fedora DVD: packages come from the disc" \
  bash -c 'ks_for fedora 45 dvd && grep -qx cdrom "$T/ks-out"'

printf 'org=1234567\nkey=secret-activation-key\n' > "$T/rhsm"
check "RHEL boot ISO: the installer registers with the activation key" \
  bash -c 'ks_for rhel 10 net "$T/rhsm" && grep -qx "rhsm --organization=1234567 --activation-key=secret-activation-key" "$T/ks-out"'
check "the VM's SSH host key is installed by the kickstart, so known_hosts can be pinned (#7)" \
  bash -c 'ks_for fedora 45 dvd && grep -q "BEGIN OPENSSH PRIVATE KEY" "$T/ks-out" && grep -q "restorecon /etc/ssh/ssh_host_ed25519_key" "$T/ks-out"'
check "after the install, no file holding the keys is left (#7)" \
  bash -c 'ks_for rhel 10 net "$T/rhsm" && ! grep -rlsF secret-activation-key "$T/ks-dir" && [ ! -e "$T/ks-dir/oemdrv.iso" ]'
check "an install that times out leaves no file holding the keys either (#7)" \
  bash -c '! HANG=1 ks_for rhel 10 net "$T/rhsm" 2>/dev/null && ! grep -rlsF secret-activation-key "$T/ks-dir" && [ ! -e "$T/ks-dir/oemdrv.iso" ] && [ ! -e "$T/ks-dir/ks" ]'
