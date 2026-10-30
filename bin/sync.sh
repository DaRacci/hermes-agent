#!/usr/bin/env bash
# Maintained-fork sync: rebuild main, rebase every patch, rebuild integration.
#
# Invariants
#   * main is REBUILT as upstream/main + a fixed delta, never rebased. Rebuilding
#     a delta onto a fresh tree cannot conflict, while rebasing a deletion
#     commit conflicts every time upstream touches a workflow file.
#   * every force-push is lease-checked against a sha read moments earlier.
#   * divergence (main not shaped like our own rebuild) halts the run.
#   * patch branches here are automation-owned. They are NOT the PR heads.
#
# Usage: DRY_RUN=1 sync.sh
set -euo pipefail

DRY_RUN=${DRY_RUN:-0}
UPSTREAM=${UPSTREAM:-upstream}
ORIGIN=${ORIGIN:-origin}
MAINT_DIR=${MAINT_DIR:-/tmp/maintenance}
WT_ROOT=${WT_ROOT:-/tmp/wt}
DELTA_WORKFLOW="$MAINT_DIR/ci/fork-maintenance.yml"
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }
# run: execute unless dry-run
run() {
  if [ "$DRY_RUN" = "1" ]; then printf '   [dry-run] %s\n' "$*"; else "$@"; fi
}

git config user.name  "RacciDev-Bot"
git config user.email "agent@racci.dev"

# The runner's checkout only knows origin; add upstream idempotently.
if ! git remote get-url "$UPSTREAM" >/dev/null 2>&1; then
  git remote add "$UPSTREAM" "https://github.com/NousResearch/hermes-agent.git"
fi

mkdir -p "$WT_ROOT"
declare -A RESULT=()   # slug -> clean|conflict|skipped|missing
declare -a CONFLICT_FILES=()

log "fetch"
git fetch --filter=blob:none --no-tags "$UPSTREAM" '+refs/heads/main:refs/remotes/upstream/main'
git fetch --filter=blob:none --no-tags "$ORIGIN" '+refs/heads/*:refs/remotes/origin/*'

UP=$(git rev-parse upstream/main)
MAIN=$(git rev-parse origin/main)
LAST=$(git log -1 --format='%(trailers:key=Upstream,valueonly)' "$MAIN" | tr -d '\n')
note "upstream   $UP"
note "main       $MAIN"
note "built on   ${LAST:-<none: not a rebuild commit>}"

# ── divergence guard ────────────────────────────────────────────────────────
if [ -n "$LAST" ]; then
  PREV=$(git rev-parse "$MAIN^")
  if [ "$PREV" != "$LAST" ]; then
    die "main diverged: built-on trailer says $LAST but parent is $PREV"
  fi
fi

# ── no-op ───────────────────────────────────────────────────────────────────
if [ "$LAST" = "$UP" ]; then
  log "upstream unchanged since last rebuild — nothing to do"
  echo "no-op: main already built on $UP" >> "$SUMMARY"
  exit 0
fi

# ── rebuild main ────────────────────────────────────────────────────────────
log "rebuild main on $UP"
git checkout -q --detach "$UP"
git rm -r -q .github/workflows 2>/dev/null || true
mkdir -p .github/workflows
cp "$DELTA_WORKFLOW" .github/workflows/fork-maintenance.yml
git add -A
run git commit -q -m "chore(ci): rebuild maintenance delta on upstream $UP

Delta applied to a fresh upstream tree rather than rebased onto it, so
upstream edits to workflow files can never conflict with this commit.

Upstream: $UP"
NEWMAIN=$(git rev-parse HEAD)
git branch -f main "$NEWMAIN"
run git push --force-with-lease="refs/heads/main:$MAIN" "$ORIGIN" main:main
echo "- main: $MAIN -> $NEWMAIN (upstream $UP)" >> "$SUMMARY"

# ── rebase every patch onto the rebuilt main ────────────────────────────────
log "rebase patches"
CLEAN_BRANCHES=()

while IFS=$'\t' read -r order slug branch; do
  ref="refs/remotes/origin/$branch"
  if ! git rev-parse --verify -q "$ref" >/dev/null; then
    note "$slug: branch $branch missing on fork — skipped"
    RESULT[$slug]="missing"
    continue
  fi
  OLD=$(git rev-parse "$ref")
  wt="$WT_ROOT/$slug"
  git worktree remove --force "$wt" 2>/dev/null || true
  git worktree add -q --detach "$wt" "$UP"

  # Replay only this branch's OWN commits onto the upstream tip. A commit that
  # carries the `Upstream:` trailer is a maintenance-delta rebuild; replaying
  # one onto a main that already contains the delta conflicts with itself, so
  # those are filtered out here — and never land on a patch branch again.
  own=()
  while read -r c; do
    [ -z "$c" ] && continue
    # Skip maintenance-delta commits. Two tests because the very first delta
    # commit predates the trailer: it deleted upstream's workflows, and
    # replaying it is what makes GitHub reject the push ("GitHub App ...
    # without workflows permission").
    if [ -n "$(git log -1 --format='%(trailers:key=Upstream,valueonly)' "$c" | tr -d '\n')" ]; then
      continue
    fi
    if git diff-tree --no-commit-id --name-only -r "$c" | grep -q '^\.github/workflows/'; then
      continue
    fi
    own+=("$c")
  done < <(git rev-list --reverse --no-merges "$OLD" --not "$UP")

  if [ "${#own[@]}" -eq 0 ]; then
    note "$slug: no patch commits ahead of upstream — obsolete"
    RESULT[$slug]="obsolete"
    git worktree remove --force "$wt" 2>/dev/null || true
    continue
  fi

  if ( cd "$wt" && git checkout -q -B "replay-$slug" && git cherry-pick "${own[@]}" >/dev/null 2>&1 ); then
    NEW=$( cd "$wt" && git rev-parse HEAD )
    note "$slug: clean ($OLD -> $NEW, ${#own[@]} commit(s))"
    run git push --force-with-lease="refs/heads/$branch:$OLD" "$ORIGIN" "$NEW:refs/heads/$branch"
    git update-ref "$ref" "$NEW"
    RESULT[$slug]="clean"
    CLEAN_BRANCHES+=("$branch")
  else
    files=$( cd "$wt" && git diff --name-only --diff-filter=U | paste -sd, - || true )
    ( cd "$wt" && git cherry-pick --abort >/dev/null 2>&1 || true )
    note "$slug: CONFLICT (${files:-unknown})"
    RESULT[$slug]="conflict"
    CONFLICT_FILES+=("$slug:$files")
  fi
  git worktree remove --force "$wt" 2>/dev/null || true
done < <(jq -r '.patches[] | select(.status=="active") | [.order,.slug,.branch] | @tsv' "$MAINT_DIR/manifest.json" | sort -n)

# ── rebuild integration ─────────────────────────────────────────────────────
log "rebuild integration"
git worktree remove --force "$WT_ROOT/integration" 2>/dev/null || true
git worktree add -q -B integration "$WT_ROOT/integration" "$NEWMAIN"
applied=0
for branch in "${CLEAN_BRANCHES[@]:-}"; do
  [ -z "$branch" ] && continue
  slug=${branch#patch/}
  if ( cd "$WT_ROOT/integration" && git merge --no-ff -q -m "merge patch: $slug" "origin/$branch" >/dev/null 2>&1 ); then
    applied=$((applied+1))
  else
    note "integration: merge of $branch failed — excluding"
    ( cd "$WT_ROOT/integration" && git merge --abort >/dev/null 2>&1 || true )
    RESULT[$slug]="integration-merge-failed"
  fi
done
INTEG=$( cd "$WT_ROOT/integration" && git rev-parse HEAD )
OLD_INTEG=$(git rev-parse -q --verify refs/remotes/origin/integration || true)
if [ "$INTEG" = "$OLD_INTEG" ]; then
  note "integration unchanged ($INTEG)"
else
  run git push --force-with-lease="refs/heads/integration:${OLD_INTEG:-}" "$ORIGIN" "$INTEG:refs/heads/integration"
  note "integration: ${OLD_INTEG:-<new>} -> $INTEG ($applied patch(es))"
fi
echo "- integration: $INTEG ($applied patch(es) applied)" >> "$SUMMARY"

# ── summary ─────────────────────────────────────────────────────────────────
log "result"
{
  echo ""
  echo "| patch | result |"
  echo "|---|---|"
  for slug in "${!RESULT[@]}"; do echo "| $slug | ${RESULT[$slug]} |"; done
} >> "$SUMMARY"

for entry in "${CONFLICT_FILES[@]:-}"; do
  [ -n "$entry" ] && printf 'CONFLICT %s\n' "$entry"
done

failed=0
for slug in "${!RESULT[@]}"; do
  case "${RESULT[$slug]}" in clean|obsolete) ;; *) failed=$((failed+1)) ;; esac
done
if [ "$failed" -gt 0 ]; then
  printf '!! %s patch(es) not applied — integration is INCOMPLETE\n' "$failed"
fi

echo "PATCHES_FAILED=$failed"
echo "INTEGRATION_SHA=$INTEG"
echo "UPSTREAM_SHA=$UP"
