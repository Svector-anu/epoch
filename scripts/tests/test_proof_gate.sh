#!/usr/bin/env bash
# deterministic tests for the proof gate: a stub gh on PATH, no network.
# the matrix runs identical facts through both gates (upstream/scripts/dev-loop-proof.sh verify
# and scripts/epoch-check.sh) and requires them to agree.
# shellcheck disable=SC2016,SC2034  # eval snippets and jq filters are single-quoted on purpose, and use these names
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CHECK=$ROOT/scripts/epoch-check.sh
DLP=$ROOT/upstream/scripts/dev-loop-proof.sh
EVIDENCE=$ROOT/scripts/epoch-evidence.sh
# shellcheck source=lib/scenario.sh
source "$HERE/lib/scenario.sh"
TRUSTED+=,$BUILDER,mallory
WORK=$(mktemp -d)
trap 'rm -rf "${WORK:?}"' EXIT
export PATH=$HERE/lib:$PATH

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

RUN=$(stub_name "repos/$REPO/actions/runs/99")
PULL=$(stub_name "repos/$REPO/pulls/7")
TREE=$(stub_name "repos/$REPO/git/trees/main?recursive=1")
HEADWF=$(stub_name "repos/$REPO/contents/.github/workflows/epoch-verify.yml?ref=$SHA")
ORDERF=$(stub_name "repos/$REPO/contents/memory/topics/p/orders/build-it.md?ref=main")

dlp_accepts() { # dir -> 0 when dev-loop-proof.sh verify accepts
  GH_STUB_DIR=$1 GITHUB_REPOSITORY=$REPO bash "$DLP" verify "$TARGET" "$SHA" >"$1/dlp.out" 2>"$1/dlp.err"
}
check_proof_state() { # dir -> proof.state from epoch-check
  GH_STUB_DIR=$1 "$CHECK" "$TARGET" --json --fixture "$1" --trusted-actors "$TRUSTED" 2>/dev/null | jq -r .proof.state || true
}

# name, accept|reject, shell snippet that mutates $d
matrix() {
  local name=$1 want=$2 mutation=$3 d=$WORK/m_$1 dlp=reject ec=reject
  base "$d"
  eval "$mutation"
  sync_comments "$d"
  if dlp_accepts "$d"; then dlp=accept; fi
  if [ "$(check_proof_state "$d")" = proven ]; then ec=accept; fi
  if [ "$dlp" = "$want" ] && [ "$ec" = "$want" ]; then
    ok "matrix $name -> $want"
  else
    bad "matrix $name: want $want, dev-loop-proof=$dlp epoch-check=$ec"
    [ ! -s "$d/dlp.err" ] || sed 's/^/       /' "$d/dlp.err" >&2
  fi
}

matrix faithful_run accept ':'
# suspected gap 1: a run made with other commands (`true`) must not prove this order
matrix other_commands reject 'mutate "$d" "$RUN" ".display_title |= sub(\"$GOOD_HASH\"; \"$TRUE_HASH\")"'
matrix order_edited_on_default reject 'printf "VERIFY\n    go test ./...\n" > "$d/$ORDERF"'
matrix order_not_on_default reject 'mutate "$d" "$TREE" ".tree |= map(select(.path | test(\"orders\") | not))"'
matrix order_ambiguous reject 'mutate "$d" "$TREE" ".tree += [{\"path\":\"memory/topics/q/orders/build-it.md\",\"type\":\"blob\"}]"'
matrix tree_truncated reject 'mutate "$d" "$TREE" ".truncated = true"'
matrix title_without_dispatch_id reject 'mutate "$d" "$RUN" ".display_title |= sub(\" verify-.*\$\"; \"\")"'
matrix title_other_sha reject 'mutate "$d" "$RUN" ".display_title |= sub(\"$SHA\"; \"$OLD\")"'
# suspected gap 2: the @ref is stripped from the workflow path, so the file content must be pinned
matrix modified_workflow reject 'mutate "$d" "$HEADWF" ".sha = \"blobevil\""'
matrix workflow_absent_at_head reject 'rm -f "${d:?}/${HEADWF:?}"'
matrix other_workflow reject 'mutate "$d" "$RUN" ".path = \".github/workflows/ci.yml\""'
matrix ref_suffix_with_pinned_blob accept 'mutate "$d" "$RUN" ".path = \".github/workflows/epoch-verify.yml@refs/heads/anything\""'
matrix run_other_head reject 'mutate "$d" "$RUN" ".head_sha = \"$OLD\""'
matrix run_failed reject 'mutate "$d" "$RUN" ".conclusion = \"failure\""'
matrix run_in_progress reject 'mutate "$d" "$RUN" ".status = \"in_progress\" | .conclusion = null"'
matrix run_from_push reject 'mutate "$d" "$RUN" ".event = \"push\""'
matrix run_from_schedule reject 'mutate "$d" "$RUN" ".event = \"schedule\""'
matrix run_other_repo reject 'mutate "$d" "$RUN" ".repository.full_name = \"evil/widget\""'
matrix run_unreadable reject 'rm -f "${d:?}/${RUN:?}"'
# dispatched by someone other than the account that posts the receipt
matrix run_other_actor reject 'mutate "$d" "$RUN" ".actor.login = \"mallory\" | .triggering_actor.login = \"mallory\""'
matrix run_rerun_by_other reject 'mutate "$d" "$RUN" ".triggering_actor.login = \"mallory\""'
# the branch name is what binds a pull request to its order
matrix branch_not_epoch reject 'mutate "$d" "$PULL" ".head.ref = \"feature/x\""'
matrix branch_other_order reject 'mutate "$d" "$PULL" ".head.ref = \"epoch/other\""'
matrix fork_head reject 'mutate "$d" "$PULL" ".head.repo.full_name = \"evil/widget\""'
# suspected gap 6: receipts at other heads, and duplicates
matrix receipt_older_sha reject 'mutate "$d" comments.json ".[1].body |= gsub(\"$SHA\"; \"$OLD\")"'
matrix receipt_duplicate reject 'mutate "$d" comments.json ". + [.[1]]"'
# suspected gap 4 (dev-loop-proof half): a receipt from another commenter is not read
matrix receipt_from_stranger reject 'mutate "$d" comments.json ".[1].user.login = \"mallory\""'

# the two gates share one implementation
if cmp -s "$ROOT/scripts/epoch-evidence.sh" "$ROOT/upstream/scripts/epoch-evidence.sh"; then ok "epoch-evidence.sh copies are identical"; else bad "epoch-evidence.sh copies differ"; fi

# epoch-evidence.sh: order extraction and the hash the workflow must agree with
printf '%s' "$ORDER_MD" > "$WORK/order.md"
if [ "$(bash "$EVIDENCE" commands "$WORK/order.md" 2>/dev/null)" = "$(printf 'go test ./...\nmake lint')" ]; then ok "commands: fenced block"; else bad "commands: fenced block"; fi
if [ "$(bash "$EVIDENCE" hash "$WORK/order.md" 2>/dev/null)" = "$GOOD_HASH" ]; then ok "hash: sha256 of the canonical commands"; else bad "hash: sha256 of the canonical commands"; fi
printf 'VERIFY\n\n    # a comment\n    go test ./...\n\n    make lint\n\nFORBIDDEN\n    rm -rf /\n' > "$WORK/indented.md"
if [ "$(bash "$EVIDENCE" commands "$WORK/indented.md" 2>/dev/null)" = "$(printf 'go test ./...\nmake lint')" ]; then ok "commands: indented lines, comments and later sections skipped"; else bad "commands: indented"; fi
printf 'VERIFY\n```\na\n```\nVERIFY\n```\nb\n```\n' > "$WORK/two.md"
if bash "$EVIDENCE" commands "$WORK/two.md" >/dev/null 2>&1; then bad "commands: two VERIFY sections"; else ok "commands: two VERIFY sections refused"; fi
printf 'GOAL x\n' > "$WORK/none.md"
if bash "$EVIDENCE" commands "$WORK/none.md" >/dev/null 2>&1; then bad "commands: no VERIFY section"; else ok "commands: no VERIFY section refused"; fi
printf 'VERIFY\nprose only\n' > "$WORK/prose.md"
if bash "$EVIDENCE" commands "$WORK/prose.md" >/dev/null 2>&1; then bad "commands: no commands"; else ok "commands: no commands refused"; fi
workflow_hash=$(printf '%s\n' "$CANON_COMMANDS" | grep -Ev '^[[:space:]]*(#|$)' | sha256_of)
if [ "$workflow_hash" = "$GOOD_HASH" ] \
  && grep -qF "printf '%s\\n' \"\$INPUT_COMMANDS\" | grep -Ev '^[[:space:]]*(#|\$)' | sha256sum" "$ROOT/upstream/.github/workflows/epoch-verify.yml"; then
  ok "workflow hashes the commands input the way the gate does"
else
  bad "workflow hash pipeline is missing or differs from the gate's"
fi

# suspected gap 4 (epoch-check half): trusted actors are mandatory
d=$WORK/need_trusted
base "$d"
for args in "" "--trusted-actors ,"; do
  code=0
  # shellcheck disable=SC2086
  GH_STUB_DIR=$d "$CHECK" "$TARGET" --json --fixture "$d" $args >"$d/out" 2>"$d/err" || code=$?
  if [ "$code" = 2 ] && grep -q 'trusted-actors' "$d/err"; then ok "trusted actors required (args: '${args:-none}')"; else bad "trusted actors required (args: '${args:-none}'), exit $code"; fi
done

# the pr author may not vouch for its own pull request unless allowed
for kind in proof review; do
  d=$WORK/author_$kind
  base "$d"
  if [ "$kind" = proof ]; then idx=1; want=needs-prove; else idx=0; want=needs-review; fi
  mutate "$d" comments.json ".[$idx].user.login = \"$BUILDER\""
  # the run was dispatched by the same account, as the gate requires
  if [ "$kind" = proof ]; then mutate "$d" "$RUN" ".actor.login = \"$BUILDER\" | .triggering_actor.login = \"$BUILDER\""; fi
  code=0
  out=$(GH_STUB_DIR=$d "$CHECK" "$TARGET" --json --fixture "$d" --trusted-actors "$TRUSTED") || code=$?
  if [ "$code" = 1 ] && [ "$(jq -r .next <<<"$out")" = "$want" ]; then ok "author-posted $kind receipt refused"; else bad "author-posted $kind receipt refused: exit $code next $(jq -r .next <<<"$out")"; fi
  code=0
  out=$(GH_STUB_DIR=$d "$CHECK" "$TARGET" --json --fixture "$d" --trusted-actors "$TRUSTED" --allow-author-receipts) || code=$?
  if [ "$code" = 0 ] && [ "$(jq -r .next <<<"$out")" = merge-ready ]; then ok "author-posted $kind receipt allowed by flag"; else bad "author-posted $kind receipt allowed by flag: exit $code"; fi
done

# an order that lives in another repository (the aeon instance) is found with --order-repo
d=$WORK/order_repo
base "$d"
put "$d" "repos/acme/instance" '{"default_branch":"trunk"}'
put "$d" "repos/acme/instance/git/trees/trunk?recursive=1" '{"truncated":false,"tree":[{"path":"memory/topics/p/orders/build-it.md","type":"blob"}]}'
printf '%s' "$ORDER_MD" > "$d/$(stub_name "repos/acme/instance/contents/memory/topics/p/orders/build-it.md?ref=trunk")"
rm -f "${d:?}/${TREE:?}" "${d:?}/${ORDERF:?}"
code=0
GH_STUB_DIR=$d "$CHECK" "$TARGET" --json --fixture "$d" --trusted-actors "$TRUSTED" --order-repo acme/instance >"$d/out" 2>/dev/null || code=$?
if [ "$code" = 0 ] && [ "$(jq -r .next "$d/out")" = merge-ready ]; then ok "--order-repo reads the order from the instance repo"; else bad "--order-repo reads the order from the instance repo (exit $code)"; fi
code=0
GH_STUB_DIR=$d "$CHECK" "$TARGET" --json --fixture "$d" --trusted-actors "$TRUSTED" >"$d/out" 2>/dev/null || code=$?
if [ "$code" = 1 ] && [ "$(jq -r .proof.state "$d/out")" = invalid ]; then ok "without --order-repo the order is looked up in the target repo only"; else bad "default order repo (exit $code)"; fi

# suspected gap 5: receipts on the second page of reviews and comments are read by the live path
d=$WORK/live_pages
base "$d"
noise() { jq -cn --argjson n "$1" '[range($n) | {user:{login:"human"}, body:"noise", html_url:"https://x", state:"COMMENTED", commit_id:"c", submitted_at:"2026-01-01T00:00:00Z"}]'; }
review_as_review=$(review_comment "$SHA" approve-ready 0 0 "$REVIEWER" | jq -c --arg s "$SHA" '. + {state:"COMMENTED", commit_id:$s, submitted_at:"2026-01-02T00:00:00Z"}')
put_page "$d" "repos/$REPO/pulls/7/reviews?per_page=100" 1 "$(noise 30)"
put_page "$d" "repos/$REPO/pulls/7/reviews?per_page=100" 2 "[$review_as_review]"
rm -f "${d:?}/$(stub_name "repos/$REPO/issues/7/comments?per_page=100").p1"
put_page "$d" "repos/$REPO/issues/7/comments?per_page=100" 1 "$(noise 30)"
put_page "$d" "repos/$REPO/issues/7/comments?per_page=100" 2 "[$(proof_comment "$SHA" '{}' "$PROVER")]"
jq -n --arg s "$SHA" --arg a "$BUILDER" '{number:7,state:"OPEN",isDraft:false,headRefOid:$s,mergeable:"MERGEABLE",mergeStateStatus:"CLEAN",author:{login:$a},
  statusCheckRollup:[{__typename:"CheckRun",name:"build",status:"COMPLETED",conclusion:"SUCCESS",detailsUrl:"https://ci/1"}]}' > "$d/pr_view"
jq -n --arg s "$SHA" '{headRefOid:$s}' > "$d/pr_view_head"
echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' > "$d/graphql"
code=0
GH_STUB_DIR=$d "$CHECK" "$TARGET" --json --trusted-actors "$TRUSTED" >"$d/out" 2>"$d/err" || code=$?
if [ "$(jq -r .next "$d/out" 2>/dev/null)" = merge-ready ]; then ok "live read follows pagination past 30 reviews and comments"; else bad "live read pagination (next $(jq -r .next "$d/out" 2>/dev/null))"; fi
# the temp dir trap must not turn a ready verdict into a failing exit status
if [ "$code" = 0 ] && [ ! -s "$d/err" ]; then ok "live run exits 0 and quietly when ready"; else bad "live run exit $code: $(head -c 200 "$d/err")"; fi

# skill snippets that count receipts must read every page, as the gate does
for pattern in 'pulls/<N>/reviews' 'issues/<N>/comments'; do
  missing=$(grep -rn --include=SKILL.md -e "gh api.*$pattern" "$ROOT/skills" | grep -v -e '--paginate' || true)
  if [ -z "$missing" ]; then ok "skills paginate $pattern"; else bad "skills read $pattern without --paginate: $missing"; fi
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
