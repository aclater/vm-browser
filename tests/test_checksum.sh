# shellcheck shell=bash disable=SC2016  # the checks are bash -c scripts, expanded when they run
# Fedora image verification (#5): only the signed part of CHECKSUM counts, and only a signature
# by the pinned key. Uses throwaway keys made here, so no network is needed.

export GNUPGHOME="$T/gnupg"; mkdir -m 700 "$GNUPGHOME"
gpg -q --batch --passphrase '' --quick-gen-key 'Release key <release@example.test>' ed25519 sign never 2>/dev/null
gpg -q --batch --passphrase '' --quick-gen-key 'Other key <other@example.test>' ed25519 sign never 2>/dev/null
FPR_RELEASE=$(gpg --with-colons 2>/dev/null --list-keys release@example.test | awk -F: '/^fpr/{print $10; exit}')
FPR_OTHER=$(gpg --with-colons 2>/dev/null --list-keys other@example.test | awk -F: '/^fpr/{print $10; exit}')
gpg -q --export > "$T/keyring.gpg"
export FPR_RELEASE FPR_OTHER
GOOD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EVIL=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
printf '# Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2: 600000000 bytes\nSHA256 (Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2) = %s\n' "$GOOD" \
  | gpg -q --batch --clearsign --local-user release@example.test > "$T/CHECKSUM"
printf 'SHA256 (Fedora-Cloud-Base-Generic-44-0.1.x86_64.qcow2) = %s\n' "$EVIL" > "$T/evil-line"
cat "$T/evil-line" "$T/CHECKSUM" > "$T/CHECKSUM.before"
cat "$T/CHECKSUM" "$T/evil-line" > "$T/CHECKSUM.after"
sed "s/$GOOD/$EVIL/" "$T/CHECKSUM" > "$T/CHECKSUM.altered"
gpg -q --batch --clearsign --local-user other@example.test < "$T/evil-line" > "$T/CHECKSUM.otherkey"


# entry FILE: the image and hash vm-browser takes from FILE, checked against the release key.
entry_is_good() {
  bash -c 'source ./vm-browser.sh; [ "$(verify_signed "$1" "$T/keyring.gpg" "$FPR_RELEASE" | fedora_cloud_entry 44)" = "$2" ]' \
    _ "$1" "Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2 $GOOD"
}
check "a good CHECKSUM gives the signed image and hash" entry_is_good "$T/CHECKSUM"
check "unsigned text before the signed block is ignored" entry_is_good "$T/CHECKSUM.before"
check "unsigned text after the signed block is ignored" entry_is_good "$T/CHECKSUM.after"
fails "an altered signed block is refused" \
  bash -c 'source ./vm-browser.sh; verify_signed "$T/CHECKSUM.altered" "$T/keyring.gpg" "$FPR_RELEASE"'
fails "a good signature by another key is refused" \
  bash -c 'source ./vm-browser.sh; verify_signed "$T/CHECKSUM.otherkey" "$T/keyring.gpg" "$FPR_RELEASE"'
fails "a file without a signature is refused" \
  bash -c 'source ./vm-browser.sh; verify_signed "$T/evil-line" "$T/keyring.gpg" "$FPR_RELEASE"'
check "the CHECKSUM parser ignores other releases' images" \
  bash -c 'source ./vm-browser.sh; [ -z "$(printf "SHA256 (Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2) = %064d\n" 0 | fedora_cloud_entry 44)" ]'
check "every pinned Fedora key is a 40-digit fingerprint" \
  bash -c 'source ./vm-browser.sh; for v in "${!FEDORA_KEYS[@]}"; do [[ ${FEDORA_KEYS[$v]} =~ ^[0-9A-F]{40}$ ]] || exit 1; done'
fails "a Fedora release without a pinned key is refused before downloading" \
  bash -c 'source ./vm-browser.sh; VER=30 DIR=$T; fetch_fedora_cloud'
