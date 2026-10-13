#!/usr/bin/env bash
# SessionStart hook for the dev-stack plugin.
#
# Tells the model when to load the engineering-delivery skill without the user asking for it,
# and lists unfinished delivery ledgers (<repo>/.delivery/*/progress.md whose last lifecycle
# item is unticked) so a fresh or compacted session resumes them instead of starting over.
#
# Reads the SessionStart event JSON on stdin (fields used: source, cwd) without needing jq.
# Prints hookSpecificOutput JSON on stdout. Writes nothing, never blocks, always exits 0.
# Plain bash 3.2 so it runs on stock macOS.

input=""
if [ ! -t 0 ]; then
  input=$(cat 2>/dev/null || true)
fi

field() {
  printf '%s' "$input" | tr -d '\n' |
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

source=$(field source)
cwd=$(field cwd)
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd=$PWD

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' | awk '{ printf "%s%s", (NR > 1 ? "\\n" : ""), $0 }'
}

msg="The dev-stack plugin is installed. When a request needs multi-step code changes that will be merged (a feature, a refactor or port across modules, a protocol, API, wire-format or schema change, a data migration, work across several repos, a deploy or release, or a benchmark-driven speed-up), load the engineering-delivery skill (Skill tool, dev-stack:engineering-delivery) before brainstorming or planning, even if the user does not mention it. Skip it for questions, explanations, read-only investigation and fixes of one or two files."

root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
open=""
count=0
if [ -n "$root" ] && [ -d "$root/.delivery" ]; then
  for ledger in "$root"/.delivery/*/progress.md; do
    [ -f "$ledger" ] || continue
    if grep -q '^- \[ \] 9\.' "$ledger" 2>/dev/null; then
      count=$((count + 1))
      [ $count -le 5 ] && open="$open
- ${ledger#"$root"/}"
    fi
  done
fi

if [ $count -gt 0 ]; then
  if [ "$source" = "compact" ]; then
    lead="Context was just compacted and this repo has unfinished delivery work."
  else
    lead="This repo has unfinished delivery work."
  fi
  msg="$msg

$lead Ledgers:$open
If the user's request concerns that work, or they ask to continue, load engineering-delivery and follow its recovery procedure (read the ledger, check it against git log) before doing anything else. Trust the ledger and git log over memory."
fi

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$(json_escape "$msg")"
exit 0
