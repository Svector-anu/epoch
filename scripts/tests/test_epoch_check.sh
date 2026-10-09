#!/usr/bin/env bash
# deterministic tests for epoch-check.sh: pre-recorded json, no network.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECK=$HERE/../epoch-check.sh
source "$HERE/lib/scenario.sh"
TRUSTED+=,other-bot
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export PATH=$HERE/lib:$PATH

pass=0
fail=0

# case <name> <expected-exit> <expected-next> <jq-mutation-on-file:file:filter>...
run_case() {
  local name=$1 want_exit=$2 want_next=$3
  shift 3
  local d=$WORK/$name m file filter out code next
  base "$d"
  for m in "$@"; do
    file=${m%%::*}
    filter=${m#*::}
    jq "$filter" "$d/$file.json" > "$d/tmp" && mv "$d/tmp" "$d/$file.json"
  done
  code=0
  out=$(GH_STUB_DIR=$d "$CHECK" "$TARGET" --json --fixture "$d" --trusted-actors "$TRUSTED") || code=$?
  next=$(jq -r .next <<<"$out")
  if [ "$code" = "$want_exit" ] && [ "$next" = "$want_next" ]; then
    pass=$((pass + 1)); printf 'ok   %-28s exit=%s next=%s\n' "$name" "$code" "$next"
  else
    fail=$((fail + 1)); printf 'FAIL %-28s exit=%s (want %s) next=%s (want %s)\n' "$name" "$code" "$want_exit" "$next" "$want_next"
    jq -c '{blocking, review, proof}' <<<"$out" >&2
  fi
}

run_case ready 0 merge-ready
run_case draft 1 wait-ci "pr::.isDraft = true"
run_case closed 1 closed "pr::.state = \"CLOSED\""
run_case merged 1 merged "pr::.state = \"MERGED\""
run_case dirty 1 rebase-needed "pr::.mergeStateStatus = \"DIRTY\" | .mergeable = \"CONFLICTING\""
run_case behind 1 rebase-needed "pr::.mergeStateStatus = \"BEHIND\""
run_case ci_red 1 needs-repair "checks::.[0].conclusion = \"FAILURE\""
run_case ci_red_blocked 1 needs-repair "checks::.[0].conclusion = \"FAILURE\"" "pr::.mergeStateStatus = \"BLOCKED\""
run_case ci_pending 1 wait-ci "checks::.[0].status = \"IN_PROGRESS\" | .[0].conclusion = \"\""
run_case ci_none 0 merge-ready "checks::[]"
run_case status_context_pending 1 wait-ci "checks::. + [{\"__typename\":\"StatusContext\",\"context\":\"deploy\",\"state\":\"PENDING\",\"targetUrl\":\"https://ci/2\"}]"
run_case open_thread 1 address-threads "threads::[{isResolved:false,isOutdated:false,path:\"a.go\",line:3,comments:{nodes:[{author:{login:\"human\"},body:\"please rename\",url:\"https://x/t\"}]}}]"
run_case resolved_thread 0 merge-ready "threads::[{isResolved:true,isOutdated:false,path:\"a.go\",line:3,comments:{nodes:[{author:{login:\"human\"},body:\"done\",url:\"https://x/t\"}]}}]"
run_case changes_requested 1 address-threads "reviews::[{state:\"CHANGES_REQUESTED\",user:{login:\"human\"},submitted_at:\"2026-01-01T00:00:00Z\",commit_id:\"$SHA\",html_url:\"https://x/r\",body:\"no\"}]"
run_case changes_then_approved 0 merge-ready "reviews::[{state:\"CHANGES_REQUESTED\",user:{login:\"human\"},submitted_at:\"2026-01-01T00:00:00Z\",commit_id:\"$SHA\",body:\"no\"},{state:\"APPROVED\",user:{login:\"human\"},submitted_at:\"2026-01-02T00:00:00Z\",commit_id:\"$SHA\",body:\"ok\"}]"
run_case review_absent 1 needs-review "comments::[.[1]]"
run_case review_old_sha 1 needs-review "comments::[.[0] | .body |= gsub(\"$SHA\"; \"$OLD\")] + [.[1]]"
run_case review_blocked 1 needs-repair "comments::[$(review_comment "$SHA" blocked 1 0 reviewer-bot)] + [.[1]]"
run_case review_discussion_open 1 needs-repair "comments::[$(review_comment "$SHA" discussion-needed 0 2 reviewer-bot)] + [.[1]]"
run_case review_discussion_zero 1 needs-review "comments::[$(review_comment "$SHA" discussion-needed 0 0 reviewer-bot)] + [.[1]]"
run_case review_two_receipts 1 needs-review "comments::. + [$(review_comment "$SHA" approve-ready 0 0 other-bot)]"
run_case review_forged_keys 1 needs-review "comments::[.[0] | .body |= sub(\"\\\"issues\\\":0\"; \"\\\"issues\\\":0,\\\"extra\\\":1\")] + [.[1]]"
run_case review_count_mismatch 1 needs-review "comments::[.[0] | .body |= (\"- [ISSUE] hidden\\n\" + .)] + [.[1]]"
run_case proof_absent 1 needs-prove "comments::[.[0]]"
run_case proof_old_sha 1 needs-prove "comments::[.[0], (.[1] | .body |= gsub(\"$SHA\"; \"$OLD\"))]"
run_case proof_two_receipts 1 needs-prove "comments::. + [$(proof_comment "$SHA" '{}' other-bot)]"
run_case proof_forged_keys 1 needs-prove "comments::[.[0], (.[1] | .body |= sub(\"\\\"kind\\\":\\\"verify-run\\\"\"; \"\\\"kind\\\":\\\"verify-run\\\",\\\"skill\\\":\\\"x\\\"\"))]"
run_case proof_other_repo_url 1 needs-prove "comments::[.[0], $(proof_comment "$SHA" '{"evidence_url":"https://github.com/evil/other/actions/runs/99"}' prover-bot)]"
run_case proof_aeon_skill_ok 0 merge-ready "comments::[.[0], $(proof_comment "$SHA" '{"kind":"aeon-skill","skill":"epoch-prove"}' prover-bot | jq -c '.body |= sub("\"order\":\"build-it\",?"; "")')]"
run_case proof_bad_verdict 1 needs-prove "comments::[.[0], $(proof_comment "$SHA" '{"verdict":"claimed"}' prover-bot)]"

# head moved between two reads: pr2.json is the second read
d=$WORK/head_moved
base "$d"
jq -n --arg s "$OLD" '{headRefOid: $s}' > "$d/pr2.json"
code=0
out=$(GH_STUB_DIR=$d "$CHECK" "$TARGET" --json --fixture "$d" --trusted-actors "$TRUSTED") || code=$?
if [ "$code" = 1 ] && [ "$(jq -r '.head_moved.to' <<<"$out")" = "$OLD" ] && [ "$(jq -r '.blocking[0]' <<<"$out")" = "head moved from $SHA to $OLD: receipts at the old head no longer count" ]; then
  pass=$((pass + 1)); echo "ok   head_moved                   exit=1"
else
  fail=$((fail + 1)); echo "FAIL head_moved"
fi

# trusted-actors: a receipt from an untrusted account does not count
d=$WORK/trusted
base "$d"
code=0
out=$(GH_STUB_DIR=$d "$CHECK" "$TARGET" --json --fixture "$d" --trusted-actors reviewer-bot) || code=$?
if [ "$code" = 1 ] && [ "$(jq -r .next <<<"$out")" = needs-prove ]; then
  pass=$((pass + 1)); echo "ok   trusted_actors_filter        exit=1 next=needs-prove"
else
  fail=$((fail + 1)); echo "FAIL trusted_actors_filter"
fi

# the receipt posters are named
base "$WORK/ready"
out=$(GH_STUB_DIR=$WORK/ready "$CHECK" "$TARGET" --fixture "$WORK/ready" --trusted-actors "$TRUSTED")
if grep -q 'by reviewer-bot' <<<"$out" && grep -q 'by prover-bot' <<<"$out"; then
  pass=$((pass + 1)); echo "ok   names_receipt_authors"
else
  fail=$((fail + 1)); echo "FAIL names_receipt_authors"
fi

# input validation happens before any read
for bad in "acme/widget" "acme/widget#0" "acme widget#1" "\$(id)/x#1" "acme/widget#1;ls"; do
  code=0
  "$CHECK" "$bad" --fixture "$WORK/ready" --trusted-actors "$TRUSTED" >/dev/null 2>&1 || code=$?
  if [ "$code" = 2 ]; then pass=$((pass + 1)); echo "ok   rejects '$bad'"; else fail=$((fail + 1)); echo "FAIL rejects '$bad' (exit $code)"; fi
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
