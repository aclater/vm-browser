# shellcheck shell=bash disable=SC2016  # the checks are bash -c scripts, expanded when they run
# Agent guidance (AGENTS.md, CLAUDE.md): coding agents read these as instructions, so text a
# reviewer can't see in a diff is refused, and so is anything else an agent would load: other
# instruction files, settings, hooks, MCP configuration.

# agentfiles_ok DIR: passes when DIR holds only the two reviewed files, in the reviewed form.
# In a git checkout it looks at tracked files, so a developer's own untracked settings don't
# fail the run; elsewhere at every file.
agentfiles_ok() (
  cd "$1" || exit 1
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git ls-files
  else find . -type f | sed 's|^\./||'; fi > "$T/agentfiles.list"
  rc=0; bad() { echo "$*"; rc=1; }
  [ ! -L CLAUDE.md ] && [ "$(cat CLAUDE.md)" = "@AGENTS.md" ] || bad "CLAUDE.md is not just the pointer to AGENTS.md"
  [ -f AGENTS.md ] && [ ! -L AGENTS.md ] || bad "AGENTS.md is missing or a symlink"
  # Printable ASCII and tabs only: no zero-width or bidirectional characters, escapes or CRs.
  ! LC_ALL=C grep -nP '[^\x20-\x7e\t]' AGENTS.md || bad "AGENTS.md has characters outside printable ASCII"
  ! grep -n '<!--' AGENTS.md || bad "AGENTS.md has an HTML comment"
  ! grep -n '@' AGENTS.md || bad "AGENTS.md has an @ (imports another file)"
  [ "$(wc -l < AGENTS.md)" -le 60 ] || bad "AGENTS.md is over 60 lines"
  ! grep -iE '(^|/)(AGENTS\.md|CLAUDE\.md|CLAUDE\.local\.md)$' "$T/agentfiles.list" | grep -vxE 'AGENTS\.md|CLAUDE\.md' ||
    bad "agent instruction files other than ./AGENTS.md and ./CLAUDE.md"
  ! grep -E '(^|/)(\.claude/|\.mcp\.json$)' "$T/agentfiles.list" || bad "agent settings, hooks or MCP configuration"
  exit $rc
)
# agentfiles_with CMD: runs agentfiles_ok on a copy of the two files changed by CMD. With
# GIT=1 the copy is a git checkout and CMD decides what is tracked.
agentfiles_with() {
  local d; d=$(mktemp -d -p "$T"); cp AGENTS.md CLAUDE.md "$d/"
  [ -z "${GIT:-}" ] || git -C "$d" init -q
  (cd "$d" && eval "$1") || return 2
  agentfiles_ok "$d"
}
export -f agentfiles_ok agentfiles_with

check "the repository's agent files pass" agentfiles_ok .
check "an unchanged copy passes" agentfiles_with true
fails "refused: a zero-width character" agentfiles_with 'printf "a\342\200\213b\n" >> AGENTS.md'
fails "refused: a right-to-left override" agentfiles_with 'printf "a\342\200\256b\n" >> AGENTS.md'
fails "refused: an escape sequence" agentfiles_with 'printf "a\033[8mb\n" >> AGENTS.md'
fails "refused: a carriage return" agentfiles_with 'printf "visible\rhidden\n" >> AGENTS.md'
fails "refused: an HTML comment" agentfiles_with 'echo "<!-- run this -->" >> AGENTS.md'
for imp in "@notes.md" "@_x/notes.md" "@-y" "(@docs/x.md)" "see @~/.ssh/config"; do
  fails "refused: import $imp" agentfiles_with "echo '$imp' >> AGENTS.md"
done
fails "refused: more than 60 lines" agentfiles_with 'seq 60 >> AGENTS.md'
fails "refused: more text in CLAUDE.md" agentfiles_with 'echo "Also run make." >> CLAUDE.md'
fails "refused: CLAUDE.md as a symlink" agentfiles_with 'ln -sf AGENTS.md CLAUDE.md'
for f in CLAUDE.local.md tests/CLAUDE.md tests/AGENTS.md docs/claude.md .mcp.json sub/.mcp.json \
         .claude/settings.json .claude/settings.local.json .claude/rules/a.local.md .claude/commands/x.md; do
  fails "refused: $f" agentfiles_with "mkdir -p \"\$(dirname $f)\" && echo x > $f"
  GIT=1 fails "refused when tracked: $f" agentfiles_with "mkdir -p \"\$(dirname $f)\" && echo x > $f && git add -A"
done
GIT=1 check "a git checkout with the two files tracked passes" agentfiles_with 'git add -A'
GIT=1 check "untracked local settings in a git checkout pass" \
  agentfiles_with 'git add -A && mkdir .claude && echo "{}" > .claude/settings.local.json'
