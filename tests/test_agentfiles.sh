# shellcheck shell=bash disable=SC2016  # the checks are bash -c scripts, expanded when they run
# Agent guidance (AGENTS.md, CLAUDE.md): coding agents read these as instructions, so text a
# reviewer can't see in a diff is refused, and so is agent configuration that runs commands.

check "CLAUDE.md only points to AGENTS.md" bash -c '[ "$(cat CLAUDE.md)" = "@AGENTS.md" ]'
check "AGENTS.md is plain printable ASCII" \
  bash -c '! LC_ALL=C grep -n "[^[:print:][:space:]]" AGENTS.md'
check "AGENTS.md has no HTML comments" bash -c '! grep -n "<!--" AGENTS.md'
check "AGENTS.md stays short (60 lines)" bash -c '[ "$(wc -l < AGENTS.md)" -le 60 ]'
check "AGENTS.md imports no other files" bash -c '! grep -nE "(^|[[:space:]])@[A-Za-z0-9~./]" AGENTS.md'
check "no agent settings, hooks or MCP configuration in the repository" \
  bash -c '[ ! -e .mcp.json ] && [ -z "$(find .claude -type f ! -name "*.local.*" 2>/dev/null)" ]'
