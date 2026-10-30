#!/usr/bin/env bash
# Issue bookkeeping for the maintained fork.
#
#   issues.sh <results.tsv> <upstream-sha> <integration-sha>
#
# results.tsv: one row per patch — slug \t status \t comma-separated conflicted files
#
# Behaviour
#   * a patch that no longer applies owns exactly one open issue
#     (`patch conflict: <slug>`, marker in the body), created on first failure
#     and reused afterwards — never duplicated
#   * the issue closes itself once the patch applies cleanly again
#   * one pinned dashboard issue (`Patch status`) is rewritten in place
#
# Idempotent: safe to run on every pipeline run. Body edits do not notify;
# comments are only added on state transitions.
set -euo pipefail

RESULTS=${1:?results file required}
UP=${2:-unknown}
INTEG=${3:-unknown}
REPO=${GH_REPO:-DaRacci/hermes-agent}
MAINT=${MAINT_DIR:-/tmp/maintenance}
MANIFEST="$MAINT/manifest.json"

CONFLICT_LABEL="patch-conflict"
DASH_LABEL="maintenance"
DASH_MARKER="<!-- hermes-maint:dashboard -->"
DASH_TITLE="Patch status"

say() { printf '   issues: %s\n' "$*"; }

gh issue list --repo "$REPO" --limit 1 >/dev/null 2>&1 || { say "issues unavailable (disabled or no auth)"; exit 0; }

for label in "$CONFLICT_LABEL" "$DASH_LABEL"; do
  gh label create "$label" --repo "$REPO" --color BFD4F2 \
    --description "maintained-fork automation" >/dev/null 2>&1 || true
done

issues=$(gh issue list --repo "$REPO" --state all --limit 200 --json number,title,body,state 2>/dev/null || echo '[]')

find_by_marker() {
  jq -r --arg m "$1" '[.[] | select((.body // "") | contains($m))] | first | .number // empty' <<<"$issues"
}
state_of() {
  jq -r --argjson n "$1" '.[] | select(.number == $n) | .state' <<<"$issues"
}
tests_for() {
  [ -f "$MANIFEST" ] || { echo ""; return; }
  jq -r --arg s "$1" '.patches[] | select(.slug == $s) | (.tests // []) | join(" ")' "$MANIFEST" 2>/dev/null || echo ""
}
pr_for() {
  [ -f "$MANIFEST" ] || { echo ""; return; }
  jq -r --arg s "$1" '.patches[] | select(.slug == $s) | (.upstream_pr // "") | tostring' "$MANIFEST" 2>/dev/null || echo ""
}

conflict_body() {
  local slug=$1 files=$2 tests files_fmt
  tests=$(tests_for "$slug")
  if [ -n "${files:-}" ]; then
    files_fmt="\`${files//,/\`, \`}\`"
  else
    files_fmt="unknown"
  fi
  cat <<EOF
<!-- hermes-maint:patch=$slug -->
\`patch/$slug\` no longer applies to the current \`main\`.

| | |
|---|---|
| conflicted files | ${files_fmt} |
| upstream | \`$UP\` |
| integration build | \`$INTEG\` |

### Reproduce

\`\`\`bash
cd /data/workspace/maintainer/hermes-agent
git fetch origin upstream --filter=blob:none
git checkout -B "patch/$slug" "origin/patch/$slug"
git rebase --onto origin/main "\$(git merge-base origin/main "patch/$slug")"
\`\`\`

### Resolve

Resolve to upstream's **current** shape, not the patch's original shape, then:

\`\`\`bash
.venv/bin/python scripts/check
HERMES_PYTHON="\$PWD/.venv/bin/python" bash scripts/run_tests.sh ${tests:-<targeted test files>}
git push --force-with-lease origin "HEAD:patch/$slug"
\`\`\`

The next maintenance run replays the patch and closes this issue automatically.

_Opened by the fork-maintenance pipeline._
EOF
}

opened=0; closed=0; updated=0

while IFS=$'\t' read -r slug status files; do
  [ -n "${slug:-}" ] || continue
  marker="<!-- hermes-maint:patch=$slug -->"
  num=$(find_by_marker "$marker")

  if [ "$status" = "conflict" ]; then
    body=$(conflict_body "$slug" "${files:-}")
    if [ -z "$num" ]; then
      gh issue create --repo "$REPO" --title "patch conflict: $slug" \
        --label "$CONFLICT_LABEL" --body "$body" >/dev/null
      opened=$((opened + 1))
      say "opened conflict issue for $slug"
    elif [ "$(state_of "$num")" = "CLOSED" ]; then
      gh issue reopen "$num" --repo "$REPO" >/dev/null
      gh issue comment "$num" --repo "$REPO" --body \
        "Conflicts again as of upstream \`$UP\` (integration \`$INTEG\`); see the updated body." >/dev/null
      gh issue edit "$num" --repo "$REPO" --body "$body" >/dev/null
      opened=$((opened + 1))
      say "reopened conflict issue #$num for $slug"
    else
      gh issue edit "$num" --repo "$REPO" --body "$body" >/dev/null
      updated=$((updated + 1))
    fi
  elif [ -n "$num" ] && [ "$(state_of "$num")" = "OPEN" ]; then
    gh issue comment "$num" --repo "$REPO" --body \
      "\`patch/$slug\` applies cleanly again — integration \`$INTEG\` on upstream \`$UP\`. Closed automatically." >/dev/null
    gh issue close "$num" --repo "$REPO" >/dev/null
    closed=$((closed + 1))
    say "closed conflict issue #$num for $slug"
  fi
done < "$RESULTS"

# ── dashboard ───────────────────────────────────────────────────────────────
dash_rows=""
if [ -f "$MANIFEST" ]; then
  while IFS=$'\t' read -r slug branch order; do
    status=$(awk -F'\t' -v s="$slug" '$1 == s { print $2 }' "$RESULTS" 2>/dev/null)
    [ -n "$status" ] || status="not attempted"
    pr=$(pr_for "$slug")
    pr_cell=${pr:+#$pr}; pr_cell=${pr_cell:--}
    dash_rows+="| \`$slug\` | $pr_cell | $status |"$'\n'
  done < <(jq -r '.patches[] | [.slug, .branch, (.order|tostring)] | @tsv' "$MANIFEST" | sort -k3 -n)
fi
[ -n "$dash_rows" ] || dash_rows="| — | — | — |"$'\n'

dash_body=$(cat <<EOF
$DASH_MARKER
Maintained by the \`Fork maintenance\` workflow. Rewritten on every run — do not edit by hand.

| upstream | integration |
|---|---|
| \`$UP\` | \`$INTEG\` |

| patch | upstream PR | status |
|---|---|---|
${dash_rows}
Status values: \`clean\` (applied to integration), \`conflict\` (issue open),
\`obsolete\` (upstream carries an equivalent change), \`missing\` (branch absent),
\`not attempted\`.

_Last updated by the fork-maintenance pipeline._
EOF
)

dash_num=$(find_by_marker "$DASH_MARKER")
if [ -z "$dash_num" ]; then
  gh issue create --repo "$REPO" --title "$DASH_TITLE" --label "$DASH_LABEL" --body "$dash_body" >/dev/null
  say "created dashboard issue '$DASH_TITLE'"
else
  gh issue edit "$dash_num" --repo "$REPO" --body "$dash_body" >/dev/null
fi

say "done (opened=$opened closed=$closed updated=$updated)"
