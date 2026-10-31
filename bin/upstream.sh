#!/usr/bin/env bash
# Cut a clean submit branch for one patch: upstream/main + that patch's own
# commits, nothing else.
#
# Why this exists: every patch branch is based on our rebuilt `main`, whose delta
# commit deletes all 56 upstream workflow files so the fork can run its own
# automation with GITHUB_TOKEN. Pushing such a branch as a PR head is either
# rejected (an App token may not create workflow files) or, with a workflow-scoped
# token, opens a PR that proposes deleting upstream's CI. The submit branch is the
# same patch replayed onto a bare upstream tree, so the diff is only the patch.
#
# The glob check is the point of the tool: it refuses to push when the resulting
# diff touches anything the manifest does not claim for that patch.
#
# Usage:
#   bin/upstream.sh --submit <slug>             # build + verify + push the branch
#   bin/upstream.sh --submit <slug> --open-pr   # ... and open the PR upstream
#   DRY_RUN=1 bin/upstream.sh --submit <slug>   # print the plan, touch nothing
set -euo pipefail

UPSTREAM=${UPSTREAM:-upstream}
ORIGIN=${ORIGIN:-origin}
UPSTREAM_REPO=${UPSTREAM_REPO:-NousResearch/hermes-agent}
DRY_RUN=${DRY_RUN:-0}
MAINT_DIR=${MAINT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}

SLUG=""
PUSH_TO=""
OPEN_PR=0
FORCE=0

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }
run() {
  if [ "$DRY_RUN" = "1" ]; then printf '   [dry-run] %s\n' "$*"; else "$@"; fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --submit)  SLUG=${2:-}; shift 2 ;;
    --open-pr) OPEN_PR=1; shift ;;
    --force)   FORCE=1; shift ;;
    --push-to) PUSH_TO=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$SLUG" ] || die "usage: bin/upstream.sh --submit <slug> [--open-pr]"

# ── manifest lookup ─────────────────────────────────────────────────────────
[ -f "$MAINT_DIR/manifest.json" ] || die "no manifest.json in $MAINT_DIR"
meta=$(python3 - "$MAINT_DIR/manifest.json" "$SLUG" <<'PY'
import json, sys
p = next((x for x in json.load(open(sys.argv[1]))["patches"] if x["slug"] == sys.argv[2]), None)
if p is None:
    sys.exit(f"no patch named {sys.argv[2]}")
print(p["branch"]); print(p.get("upstream_pr") or ""); print("\n".join(p.get("files_glob", [])))
PY
) || die "manifest lookup failed"
BRANCH=$(printf '%s\n' "$meta" | sed -n 1p)
PR=$(printf '%s' "$meta" | sed -n 2p)
GLOBS=$(printf '%s\n' "$meta" | sed -n '3,$p')

[ -n "$PR" ] && [ "$FORCE" != "1" ] && \
  die "$SLUG already has upstream PR #$PR — rebase that PR's head instead of opening a second one (--force to override)"

log "submit $SLUG"
note "patch branch  $BRANCH"
note "submit branch submit/$SLUG"
note "globs         $(echo "$GLOBS" | tr '\n' ' ')"

# ── fetch ───────────────────────────────────────────────────────────────────
git fetch --filter=blob:none --no-tags "$UPSTREAM" '+refs/heads/main:refs/remotes/upstream/main'
git fetch --filter=blob:none --no-tags "$ORIGIN" "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
UP=$(git rev-parse upstream/main)
note "upstream/main $UP"

# ── replay only this patch's own commits onto the bare upstream tree ────────
# A commit carrying the `Upstream:` trailer is a maintenance-delta rebuild, and
# any commit touching .github/workflows is delta content: both are dropped, or
# the submit branch would carry the fork's CI surgery into the PR.
own=()
while read -r c; do
  [ -z "$c" ] && continue
  if [ -n "$(git log -1 --format='%(trailers:key=Upstream,valueonly)' "$c" | tr -d '\n')" ]; then
    note "skip delta  $(git log -1 --format='%h %s' "$c")"
    continue
  fi
  if git diff-tree --no-commit-id --name-only -r "$c" | grep -q '^\.github/workflows/'; then
    note "skip wf     $(git log -1 --format='%h %s' "$c")"
    continue
  fi
  own+=("$c")
done < <(git rev-list --reverse --no-merges "origin/$BRANCH" --not "$UP")

[ "${#own[@]}" -gt 0 ] || die "$SLUG has no commits ahead of upstream/main — nothing to submit"

note "replaying ${#own[@]} commit(s)"
for c in "${own[@]}"; do note "  $(git log -1 --format='%h %s' "$c")"; done

run git switch -q -C "submit/$SLUG" "$UP"
run git cherry-pick -x "${own[@]}"

if [ "$DRY_RUN" = "1" ]; then
  log "dry-run: stopping before the diff guard, the result and the push"
  exit 0
fi

# ── the guard: the diff must be exactly what the manifest claims ────────────
changed=$(git diff --name-only "upstream/main...HEAD")
[ -n "$changed" ] || die "empty diff against upstream/main"
bad=$(CHANGED="$changed" GLOBS="$GLOBS" python3 - <<'PYGLOB'
import os, re
pat = []
for g in os.environ["GLOBS"].splitlines():
    g = g.strip()
    if not g:
        continue
    # `**` crosses directory separators, `*` does not: a glob is not a regex, and
    # converting to a fnmatch pattern cannot express the difference.
    rx = g.replace("**", "\x00").replace("*", "[^/]*").replace("\x00", ".*")
    pat.append(re.compile("^" + rx + "$"))
bad = [f for f in os.environ["CHANGED"].split() if not any(p.match(f) for p in pat)]
print("\n".join(bad))
PYGLOB
)
if [ -n "$bad" ]; then
  printf '\n!! %s\n' "diff touches files the manifest does not claim for $SLUG:" >&2
  printf '     %s\n' $bad >&2
  die "refusing to push — widen files_glob if the patch really touches these"
fi
note "diff scope ok: $(echo "$changed" | tr '\n' ' ')"

log "result"
git log --oneline "upstream/main..HEAD"
git diff --stat "upstream/main...HEAD"

if [ -n "$PUSH_TO" ]; then
  TGT_REMOTE=${PUSH_TO%%:*}
  TGT_BRANCH=${PUSH_TO#*:}
  TGT_SHA=$(git ls-remote --heads "$TGT_REMOTE" "refs/heads/$TGT_BRANCH" | cut -f1)
  [ -n "$TGT_SHA" ] || die "$TGT_REMOTE has no branch $TGT_BRANCH — check the PR head name"
  log "force-push to $TGT_REMOTE:$TGT_BRANCH ($(echo "$TGT_SHA" | cut -c1-10) -> $(git rev-parse --short HEAD))"
  note "this rewrites a public PR head; the lease refuses if it moved since the read"
  run git push --force-with-lease="refs/heads/$TGT_BRANCH:$TGT_SHA" "$TGT_REMOTE" "HEAD:refs/heads/$TGT_BRANCH"
  echo "PUSHED=$TGT_REMOTE:$TGT_BRANCH"
  exit 0
fi

log "push submit/$SLUG"
if git rev-parse --verify -q "refs/remotes/origin/submit/$SLUG" >/dev/null; then
  run git push --force-with-lease="refs/heads/submit/$SLUG:$(git rev-parse "origin/submit/$SLUG")" \
      "$ORIGIN" "HEAD:refs/heads/submit/$SLUG"
else
  run git push "$ORIGIN" "HEAD:refs/heads/submit/$SLUG"
fi

if [ "$OPEN_PR" = "1" ]; then
  FILES=$(echo "$changed" | sed 's/^/- `/; s/$/`/')
  COMMITS=$(git log --format='- `%h` %s' "upstream/main..HEAD")
  BODY=$(cat <<EOF
## What

$(git log -1 --format='%B' HEAD | head -20)

## Commits

$COMMITS

## Files

$FILES

## Notes

Cut from upstream \`main\` at \`${UP:0:10}\`; carries only the commits above and no fork tooling
(no workflow changes, no CI delta).
EOF
)
  log "open PR"
  run gh pr create --repo "$UPSTREAM_REPO" \
      --head "$(gh api user --jq .login):submit/$SLUG" \
      --base main \
      --title "$(git log -1 --format='%s' HEAD)" \
      --body "$BODY"
fi

echo "SUBMIT_BRANCH=submit/$SLUG"
