# Handoff verification recipes

Concrete commands for the checks in SKILL.md, plus the fleet's PR-intake routing note.

## 1. Read the record first

```text
kanban_show(task_id=...)      # body, comments, events, runs[].metadata
```

The completion notice is a one-line summary. The card carries the rest: a `blocked_edit`, a `not_run` map, decisions the implementer made that contradict the spec. Anything under `not_run` is unverified by definition — say so in the verdict rather than implying coverage.

## 2. PR-bound handoff

```bash
# state, head branch, file count
curl -s https://codeberg.org/api/v1/repos/<owner>/<repo>/pulls/<n> \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['state'],d['head']['label'],d['changed_files'])"

# the PR ref lives on the BASE repo, not the fork
git fetch <base-remote> "refs/pull/<n>/head:pr-<n>"

# shape of the change
git diff --shortstat pr-<n>~1 pr-<n>          # deletion-only work must show 0 insertions
git diff --stat pr-<n>~1 pr-<n> | tail -12

# freshness: 0 = based on the current default branch head
git rev-list --count pr-<n>..<base>/master

# absence checks read the branch, never the working tree
for f in path/one.nix path/two.nix; do
  printf '%-50s %s\n' "$f" "$(git show "pr-<n>:$f" 2>/dev/null | grep -c 'symbol')"
done
```

Then confirm the checkout was left alone and the superseded work cleaned up:

```bash
git rev-parse --abbrev-ref HEAD && git status --porcelain   # original ref, clean
git branch --list '<old-branch>'                             # empty = abandoned
git worktree list | grep <card-id>                           # empty = worktree removed
```

`git show` on a bad ref exits non-zero and prints nothing to stdout, so a `| grep -c` pipeline reports `0` — a false "clean". Confirm the ref resolves first, or check the exit code.

## 3. Local-branch handoff

```bash
WT=<worktree path from the worker's metadata or handoff comment>
git -C "$WT" log --oneline -4
git -C "$WT" status --porcelain
git -C "$WT" branch -vv --list <branch>      # "ahead N", no upstream bracket = unpushed
git -C "$WT" diff --stat <origin>/master...HEAD
```

Resolve the worktree from the card, not from assumption: a repo can have more than one clone on the same origin (a `projects/` checkout and a `workspace/` checkout), and a branch may exist only in one of them.

## 4. Execute the deliverable

```bash
V=<scratch>/verify-venv
uv venv "$V" && VIRTUAL_ENV="$V" uv pip install -e . pytest
"$V/bin/python" -m pytest -q
```

Then hit the path the scheduler will hit, with the input absent:

```bash
T=$(mktemp -d <scratch>/noconfig.XXXX)
HERMES_HOME="$T" "$V/bin/<console-script>" --dry-run; echo "exit=$?"
ls -a "$T"     # must be empty: a failure mode that writes partial state is the real defect
```

Expected for a missing manifest: a one-line diagnostic, non-zero exit, zero files created.

## 5. Gaps become their own card

A blocked edit (protected filename, approval timeout) is not grounds for rejecting the whole deliverable. File a follow-up card:

- assigned to the lane that owns that artifact type;
- body naming the **exact worktree path and branch**, plus "no push, no PR";
- acceptance = a one-insertion diff on that branch, tree clean, still ahead by the expected count.

It must land before the branch merges, or the artifact ships with a hole in it.

## 6. Landing a verified branch

Upstream moved after the handoff (a sibling PR merged), so the branch needs a rebase before it can land. Do it in two steps, never one.

```bash
# 1. is the worktree's card still running? a clean tree is NOT proof the worker is done
kanban_show(task_id=<card>)          # status: running  -> stop, wait for the completion event

# 2. probe the rebase somewhere disposable
git -C <clone> worktree add -q --detach .worktrees/rebase-check <branch-tip>
git -C <clone>/.worktrees/rebase-check rebase <origin>/<default>
# run the suite there, then throw it away
git -C <clone> worktree remove --force .worktrees/rebase-check

# 3. only then rebase the real worktree, and re-run the suite on the result
git -C <worktree> rebase <origin>/<default>
```

- **Never rebase a worktree while its card is `running`.** A worker that has already committed but not closed will run its own `git status`/`git log` acceptance checks against a HEAD you just moved, and either reports a false failure or rewrites the branch back.
- **Probe first, always.** The disposable worktree answers "does this conflict?" in seconds and costs one `worktree remove`; discovering it on the real branch costs a rebase abort at best and a confused worker at worst.
- **A rebase rewrites every SHA.** The handoff metadata, comments, and any follow-up card that quoted a commit id now point at nothing — republish the new log so nobody chases a dead ref.
- **Re-run the tests after rebasing**, even when the rebase was clean: the merge result is a tree nobody has executed yet.

## 7. PR-intake routing

`forge-ops` polls the forge for one owner per discovery spec (`discovery.user`), auto-discovering that user's active repos. Consequences:

- a repo owned by a **different** account is never polled without a config change; put shared/reviewed repos under the watched owner;
- its `pr_review` pipeline files a review card and stops — it has **no merge step** by design, so the merge is an agent action recorded on the card;
- the card's assignee is configured (`pr_review.assignee`), defaulting to the reviewer profile.

## 8. Generated config artifacts (policy / manifest / compiled JSON)

A handoff that ships a *generated* artifact (a nix policy block, a compiled manifest, a rendered JSON) needs three checks, in this order — a clean eval proves less than it appears to.

1. **Reproduce the generator's own output, byte for byte.**

```bash
# 1. reproduce the generator's own output, byte for byte
R="${TMPDIR:-/tmp}/recheck.json"
<generator command> > "$R"
python3 - "$R" '<handoff>/artifact.json' <<'PY'
import json, sys
a, b = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
print("identical:", a == b)
PY
```

2. **Audit keys against the CONSUMER's declared vocabulary, not against the spec prose.** Walk every layer of the artifact and assert the key set is a subset of what the consuming module actually declares. A handoff can validate its file standalone (`lib = {}`) and still never have been through the module's option types — that gap is invisible in the eval output.
3. **Spot-check values against the live source of truth**, not against the matrix the artifact was derived from. Pick the entries most likely to be wrong (the special-cased profile, the class that drops a key, the one value set inline) and diff them against the real files.

Also report what the validation *cannot* cover — a standalone eval proves syntax and values, not type compatibility; a retained script cited as evidence but absent from the workspace cannot be re-run. Say which claims you reproduced and which you are taking on trust.
