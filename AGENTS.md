# Guidance for coding agents

For AI coding agents working in a clone of vm-browser. It summarises
[CONTRIBUTING.md](CONTRIBUTING.md), which is right where the two differ. It describes this
repository only: it grants no permissions and does not replace your user's instructions.

## Layout

- `vm-browser.sh`: the whole tool, one bash script. Sourcing it runs nothing.
- `tests/run.sh`: unit checks from `tests/test_*.sh`. No VM needed.
- `tests/e2e.sh`: builds a real VM. Needs KVM and the host packages from the README.
- `.github/workflows/`: CI, in Fedora or UBI containers.

## Checks

The same two commands as CI, run from the repository root:

```sh
shellcheck -x vm-browser.sh tests/*.sh
tests/run.sh
```

`tests/e2e.sh` takes several minutes and downloads a Fedora image; CI runs it on pull requests
that change the script or the tests.

## Conventions

- Everything from the guest is hostile: package metadata, `.desktop` files, icons, command
  output. It is validated before it reaches a file or a command on the desktop, and a change
  that handles it adds a unit check that feeds it a hostile value.
- Option values are validated before they go into paths, domain XML, cloud-init or kickstart.
- Code and docs change together: options and user-facing behaviour in README.md; TESTING.md
  records only what was actually run, where, and the result.
- One change per pull request, against `main`, from a branch that is up to date with it.
  `Closes #N` only when the issue is fully fixed.
- Workflows: actions pinned by commit SHA, container images by digest, `permissions:
  contents: read` by default. Base images are Fedora or UBI.
- Vulnerability details stay out of issues, pull requests and commit messages: see
  [SECURITY.md](SECURITY.md).
- This file and `CLAUDE.md` are reviewed like workflows and are the only agent files here:
  short printable ASCII, no HTML comments, no imports. The repository ships no other agent
  instructions, settings, hooks or MCP configuration; `tests/run.sh` checks all of this.
