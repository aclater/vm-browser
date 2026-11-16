# shellcheck shell=bash disable=SC2016  # the checks are bash -c scripts, expanded when they run
# The ISO helpers, with the real xorriso: the discs vm-browser makes, and what it takes from an
# installer ISO, which may be hostile.

mkdir -p "$T/iso/dvd/images/pxeboot" "$T/iso/dvd/BaseOS/repodata" "$T/iso/net/images/pxeboot" "$T/iso/evil/images/pxeboot" "$T/iso/ks"
for d in dvd net; do echo kernel > "$T/iso/$d/images/pxeboot/vmlinuz"; echo initrd > "$T/iso/$d/images/pxeboot/initrd.img"; done
ln -s /etc/passwd "$T/iso/evil/images/pxeboot/vmlinuz"; echo initrd > "$T/iso/evil/images/pxeboot/initrd.img"
echo 'text' > "$T/iso/ks/ks.cfg"
for d in dvd net evil; do xorrisofs -quiet -o "$T/$d.iso" -V "Test-$d-x86_64" -J -r "$T/iso/$d" 2>/dev/null; done

check "make_iso: a folder's files go to the disc's root, with the label given" \
  bash -c 'source ./vm-browser.sh; make_iso "$T/oem.iso" OEMDRV "$T/iso/ks" && [ "$(iso_label "$T/oem.iso")" = OEMDRV ] \
    && iso_extract "$T/oem.iso" /ks.cfg "$T/ks.out" && grep -qx text "$T/ks.out"'
check "make_iso: single files go to the disc's root" \
  bash -c 'source ./vm-browser.sh; make_iso "$T/seed.iso" cidata "$T/iso/ks/ks.cfg" && iso_extract "$T/seed.iso" /ks.cfg "$T/seed.out"'
check "iso_label reads the volume label" \
  bash -c 'source ./vm-browser.sh; [ "$(iso_label "$T/dvd.iso")" = Test-dvd-x86_64 ]'
check "iso_extract copies a regular file" \
  bash -c 'source ./vm-browser.sh; iso_extract "$T/dvd.iso" /images/pxeboot/vmlinuz "$T/k" && [ ! -L "$T/k" ] && grep -qx kernel "$T/k"'
check "iso_extract replaces a file left from an earlier run" \
  bash -c 'source ./vm-browser.sh; echo old > "$T/k2"; chmod 444 "$T/k2"; iso_extract "$T/dvd.iso" /images/pxeboot/vmlinuz "$T/k2" && grep -qx kernel "$T/k2"'
check "a symlink in the ISO is refused, and no link is left" \
  bash -c 'source ./vm-browser.sh; ! iso_extract "$T/evil.iso" /images/pxeboot/vmlinuz "$T/ek" && [ ! -e "$T/ek" ] && [ ! -L "$T/ek" ]'
check "a file missing from the ISO is refused" \
  bash -c 'source ./vm-browser.sh; ! iso_extract "$T/net.iso" /nope "$T/nk" && [ ! -e "$T/nk" ]'
check "a DVD's package repository is found, and a netinstall ISO has none" \
  bash -c 'source ./vm-browser.sh; iso_has_packages "$T/dvd.iso" && ! iso_has_packages "$T/net.iso"'
check "an installer ISO whose kernel is a symlink is refused before anything boots" \
  bash -c 'source ./vm-browser.sh; OS=fedora VER=45 NAME=evil DIR=$T/evil-dir IMAGE=$T/evil.iso; mkdir -p "$DIR"
    virsh() { echo "virsh called" >&2; return 1; }
    if out=$(install_from_iso key 2>&1); then exit 1; fi; grep -q "no installer kernel" <<<"$out" && ! grep -q "virsh called" <<<"$out" && [ ! -L "$DIR/vmlinuz" ]'
