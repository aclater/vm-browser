# Security policy

## Supported versions

vm-browser has no releases yet. Security fixes go into `main`; use the latest `main`.

## Reporting a vulnerability

Please don't open a public issue, pull request or discussion for a vulnerability. Report it
privately through GitHub's private vulnerability reporting:

**<https://github.com/aclater/vm-browser/security/advisories/new>**

(or the **Report a vulnerability** button on the repository's
[Security tab](https://github.com/aclater/vm-browser/security)). Only the maintainer sees the
report.

Please include the commit you ran, your desktop's distribution and compositor (GNOME, KDE,
Sway, ...), the guest (`--os`, `--version`, `--image`), the command line, what happens and, if
you can, how to reproduce it.

## What to expect

vm-browser is maintained by one person, so these are targets, not guarantees: an
acknowledgement within 7 days, an assessment within 14 days, and a fix for a confirmed issue
within 90 days, published as a GitHub security advisory, crediting you unless you'd rather not
be named. Please keep the details private until then.

## Scope

vm-browser's job is to keep a browser, and everything its packages install, inside the VM. It
treats the guest, and everything that comes out of it, as hostile: a browser exploit, a
malicious `--rpm`, or a compromised vendor repository. In scope:

- anything that lets the guest run code on the desktop, or read or change the desktop's files,
  keys or settings (for example through the launchers it writes, or what it copies out);
- the guest reaching services on the desktop that it shouldn't (see "Network" in the README);
- a download (image, checksum, keys) that isn't verified as the README says;
- credentials (the RHEL activation key, SSH keys) ending up somewhere they shouldn't.

Out of scope, documented in the README: the guest can show windows and, while one has focus,
read the clipboard; browsers in the same VM share one account; and the guest can reach the
internet.
