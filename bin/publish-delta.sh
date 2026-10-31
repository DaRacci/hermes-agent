#!/usr/bin/env bash
# Publish the maintenance delta onto main with a credential GitHub will accept.
#
# Why this exists: `.github/workflows/*` may only be created or updated by a
# credential carrying the `workflow` scope — a GITHUB_TOKEN cannot do it, so the
# sync job's own push is rejected the moment the delta's bytes change. This runs
# the same rebuild (never a rebase) from a host that holds such a credential, so
# a workflow edit ships without putting a long-lived PAT in the repository.
#
# Invariants, identical to sync.sh's rebuild:
#   * main = upstream/main + the delta, rebuilt from a fresh tree each time.
#   * divergence halts: a main not shaped like our own rebuild is a human's edit.
#   * every force-push is lease-checked against a sha read moments earlier.
#
# Usage:
#   bin/publish-delta.sh            # publish if main does not already carry it
#   DRY_RUN=1 bin/publish-delta.sh  # print the plan, push nothing
set -euo pipefail

DRY_RUN=${DRY_RUN:-0}
UPSTREAM=${UPSTREAM:-upstream}
ORIGIN=${ORIGIN:-origin}
MAINT_DIR=${MAINT_DIR:-/tmp/maintenance}
DELTA_WORKFLOW="$MAINT_DIR/ci/fork-maintenance.yml"

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }
run() {
  if [ "$DRY_RUN" = "1" ]; then printf '   [dry-run] %s\n' "$*"; else "$@"; fi
}

[ -f "$DELTA_WORKFLOW" ] || die "no delta workflow at $DELTA_WORKFLOW — set MAINT_DIR to a maintenance checkout"

git config user.name  "RacciDev-Bot"
git config user.email "agent@racci.dev"

if ! git remote get-url "$UPSTREAM" >/dev/null 2>&1; then
  git remote add "$UPSTREAM" "https://github.com/NousResearch/hermes-agent.git"
fi

log "fetch"
git fetch --filter=blob:none --no-tags "$UPSTREAM" '+refs/heads/main:refs/remotes/upstream/main'
git fetch --filter=blob:none --no-tags "$ORIGIN" '+refs/heads/main:refs/remotes/origin/main'

UP=$(git rev-parse upstream/main)
MAIN=$(git rev-parse origin/main)
LAST=$(git log -1 --format='%(trailers:key=Upstream,valueonly)' "$MAIN" | tr -d '\n')
note "upstream   $UP"
note "main       $MAIN"
note "built on   ${LAST:-<none: not a rebuild commit>}"

# ── divergence guard ────────────────────────────────────────────────────────
# main must be a commit we generated: its parent is the upstream sha in its
# own trailer. Anything else means a human pushed to main; stop rather than
# clobber it.
if [ -n "$LAST" ]; then
  PREV=$(git rev-parse "$MAIN^")
  [ "$PREV" = "$LAST" ] || die "main diverged: trailer says $LAST but parent is $PREV"
fi

# ── is there anything to publish? ───────────────────────────────────────────
DELTA_STALE=0
if ! git show "$MAIN:.github/workflows/fork-maintenance.yml" 2>/dev/null | cmp -s - "$DELTA_WORKFLOW"; then
  DELTA_STALE=1
  note "delta      stale (main does not carry the current delta)"
else
  note "delta      matches main"
fi

if [ "$LAST" = "$UP" ] && [ "$DELTA_STALE" = "0" ]; then
  log "nothing to publish"
  echo "PUBLISHED=0"
  exit 0
fi

# ── rebuild main on the current upstream tip ────────────────────────────────
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

NEW=$(git rev-parse HEAD)
log "push main $MAIN -> $NEW"
run git push --force-with-lease="refs/heads/main:$MAIN" "$ORIGIN" "HEAD:refs/heads/main"

echo "PUBLISHED=1"
echo "MAIN_SHA=$NEW"
echo "UPSTREAM_SHA=$UP"
