# shellcheck shell=bash disable=SC2016  # the checks are bash -c scripts, expanded when they run
# The kickstart written for installer ISOs (install_from_iso), checked without running an
# install: virsh, isoinfo and genisoimage are replaced by stubs that record what they get.

# ks_for OS VER ISO-KIND [RHSM-FILE]: writes the kickstart vm-browser would use to $T/ks-out.
# ISO-KIND "dvd" has packages on the disc, "net" has none.
ks_for() {
  bash -c '
    source ./vm-browser.sh
    KIND=$3 OS=$1 VER=$2 NAME=ks-test DIR=$T/ks-dir RHSM=${4:-} MEM=4 CPUS=4 DISK=12G PORT=2299 IMAGE=$T/fake.iso
    rm -rf "$DIR"; mkdir -p "$DIR"
    isoinfo() { case "$*" in *-d*) echo "Volume id: Test-Label";; *-x*) echo kernel;; *-f*) [ "$KIND" = dvd ] && echo /BaseOS/repodata;; esac; }
    genisoimage() { local o; while [ $# -gt 0 ]; do case $1 in -o) o=$2; shift;; esac; shift; done; cp "$DIR/ks/ks.cfg" "$T/ks-out"; : > "$o"; }
    virsh() { [ "$1" != domstate ]; }; qemu-img() { :; }; sleep() { :; }
    install_from_iso "ssh-ed25519 AAAATEST test" >/dev/null
  ' _ "$@"
}
export -f ks_for

check "Fedora netinstall: packages come through a metalink, not a mirrorlist" \
  bash -c 'ks_for fedora 45 net && grep -qx "url --metalink=https://mirrors.fedoraproject.org/metalink?repo=fedora-45&arch=x86_64" "$T/ks-out" && ! grep -q mirrorlist "$T/ks-out"'
check "Fedora DVD: packages come from the disc" \
  bash -c 'ks_for fedora 45 dvd && grep -qx cdrom "$T/ks-out"'
