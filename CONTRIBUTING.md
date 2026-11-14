# Contributing to vm-browser

Bug reports and pull requests are welcome.

## Reporting a bug

Open an [issue](https://github.com/aclater/vm-browser/issues) with the command line, the
guest (`--os`, `--version`, `--image`), what you expected and what happened. **Security
problems** go through a private report instead: see [SECURITY.md](SECURITY.md).

## Changing code

1. Start with an issue, so the change can be discussed first.
2. Work on a branch and open a pull request against `main`. The default branch only accepts
   pull requests whose checks pass on a branch that is up to date with `main`. If `main` moves
   while yours waits, merge it into your branch (no force-push) and let the checks run again.
3. Run the checks before you push. The unit tests need no VM:

   ```sh
   shellcheck -x vm-browser.sh tests/*.sh
   tests/run.sh
   ```

   Then build a VM with the change, as in the README, for each kind of guest it touches:
   a Fedora cloud image, a RHEL KVM image with `--rhsm`, and an installer ISO. Say in the pull
   request which ones you ran. The `e2e` workflow builds a Fedora VM on GitHub's runners.
4. Treat everything that comes from the guest (package metadata, `.desktop` files, icons,
   command output) as hostile: validate it before it goes into a file or a command on the
   desktop, and add a test to `tests/` that feeds it a hostile value.
5. Update README.md with the code: options, what was tested, and anything a user should know.

## Workflows

- Actions are pinned by commit SHA with the version in a comment, and container images by
  digest; Dependabot keeps them current.
- Every workflow starts with `permissions: contents: read` and raises them per job only where
  needed; checkouts use `persist-credentials: false`.
- CI runs in Fedora or UBI containers.
- `zizmor` checks the workflows on every pull request that changes them. Locally:
  `pipx run zizmor==1.31.1 --offline .github`.
