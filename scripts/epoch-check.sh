#!/usr/bin/env bash
# epoch-check: is one pull request ready at its current head commit?
# read-only: bash + jq + gh. never writes to the pull request.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  cat >&2 <<'USAGE'
usage: epoch-check.sh <owner/repo#N> --trusted-actors a,b [--json] [--json-file FILE] [--order-repo owner/repo]
                      [--allow-author-receipts] [--fixture DIR]
  --trusted-actors         required: the logins whose review and proof receipts count
  --order-repo             repo whose default branch holds the work orders (default: the pull request's repo)
  --allow-author-receipts  count receipts posted by the pull request's own author (one-token setups)
  exit 0 ready, 1 not ready, 2 usage or read error
USAGE
  exit 2
}

die() { echo "epoch-check: $*" >&2; exit 2; }

DECIDE=$(cat <<'JQ'
def marker($k): "<!-- aeon-" + $k + ":";
def clean: (. // "") | gsub("\r"; "");
def one_line($s): ($s | split("\n") | map(select(length > 0)) | (.[0] // "(no body)") | .[0:160]);
def run_url: "^https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[1-9][0-9]*$";
def slug: "^[a-z0-9][a-z0-9-]*$";
def nat: type == "number" and floor == . and . >= 0;

def parse($k; $body):
  ($body | clean) as $c
  | (($c | split(marker($k)) | length) - 1) as $markers
  | [$c | split("\n")[] | select(test("^<!-- aeon-" + $k + ":\\{.*\\} -->$"))] as $lines
  | if $markers != 1 then {ok: false, reason: "expected exactly one \($k) marker in the comment, found \($markers)"}
    elif ($lines | length) != 1 then {ok: false, reason: "the \($k) marker is not a single-line receipt"}
    else ($lines[0] | ltrimstr(marker($k)) | rtrimstr(" -->") | try fromjson catch null) as $r
      | if $r == null then {ok: false, reason: "\($k) receipt is not valid json"}
        else {ok: true, receipt: $r, body: $c} end
    end;

def review_valid($r; $c; $target; $sha):
  ($r | type == "object" and keys == ["critical", "issues", "schema", "sha", "target", "verdict"]
    and .schema == 1 and .target == $target and .sha == $sha
    and (.verdict == "approve-ready" or .verdict == "discussion-needed" or .verdict == "blocked")
    and (.critical | nat) and (.issues | nat)
    and (if .verdict == "approve-ready" then .critical == 0 and .issues == 0
         elif .verdict == "discussion-needed" then .critical == 0 and .issues > 0
         else .critical > 0 end))
  and ([$c | split("\n")[] | select(startswith("- [CRITICAL] "))] | length) == $r.critical
  and ([$c | split("\n")[] | select(startswith("- [ISSUE] "))] | length) == $r.issues;

def proof_valid($r; $target; $sha):
  ($target | sub("#.*$"; "")) as $repo
  | ($r | type == "object" and .schema == 1 and .target == $target and .sha == $sha and .verdict == "proven"
      and (.evidence_run_id | type == "number" and floor == . and . > 0)
      and (.evidence_url | type == "string" and test(run_url))
      and ((.kind == "aeon-skill"
              and keys == ["evidence_run_id", "evidence_url", "kind", "schema", "sha", "skill", "target", "verdict"]
              and (.skill | type == "string" and test(slug)))
           or (.kind == "verify-run"
              and keys == ["evidence_run_id", "evidence_url", "kind", "order", "schema", "sha", "target", "verdict"]
              and (.order | type == "string" and test(slug))
              and (.evidence_url | ascii_downcase)
                  == ("https://github.com/" + $repo + "/actions/runs/" + (.evidence_run_id | tostring) | ascii_downcase))));

# receipt-bearing items (reviews and comments) bound to this head, by trusted authors only.
# the pull request's own author does not count unless $allow_author: whoever wrote the change
# cannot also vouch for it.
def candidates($k; $items; $sha; $trusted; $author; $allow_author):
  [$items[]
   | select(.body | contains(marker($k)))
   | select((.author | ascii_downcase) as $a | any($trusted[]; . == $a))] as $trusted_items
  | ($trusted_items | map(select($allow_author or ((.author | ascii_downcase) != $author)))) as $all
  | {at_head: ($all | map(select((.body | contains("\"sha\":\"" + $sha + "\"")) and (.source == "comment" or .commit == $sha)))),
     all: $all,
     by_author: (($trusted_items | length) - ($all | length))}
  | . + {stale: ((.all | length) - (.at_head | length))};
def author_note($c): if $c.by_author > 0 then "; \($c.by_author) by the pull request author do not count (--allow-author-receipts)" else "" end;

def ci_state: if .__typename == "CheckRun" then
    {name, conclusion: ((.conclusion | select(. != null and . != "")) // .status), url: .detailsUrl,
     state: (if .status != "COMPLETED" then "pending"
             elif (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED") then "pass" else "red" end)}
  else {name: .context, conclusion: .state, url: .targetUrl,
        state: (if .state == "SUCCESS" then "pass" elif (.state == "PENDING" or .state == "EXPECTED") then "pending" else "red" end)}
  end;

$pr[0] as $p
| ($checks[0] // []) | map(ci_state) as $checks
| (if ($checks | length) == 0 then "none" elif any($checks[]; .state == "red") then "red"
   elif any($checks[]; .state == "pending") then "pending" else "green" end) as $ci
| ($p.headRefOid) as $sha
| (if $p.state == "MERGED" or $p.state == "CLOSED" then "closed"
   elif $p.mergeable == "CONFLICTING" or $p.mergeStateStatus == "DIRTY" then "dirty"
   elif $p.mergeStateStatus == "BEHIND" then "behind"
   elif $p.isDraft or $p.mergeStateStatus == "DRAFT" then "draft"
   elif $p.mergeStateStatus == "UNKNOWN" or $p.mergeStateStatus == null then "unknown"
   elif $p.mergeStateStatus == "BLOCKED" and $ci == "red" then "refused"
   else "allowed" end) as $github
| [($threads[0] // [])[] | select(.isResolved | not) | (.comments.nodes[0]) as $c
   | {author: ($c.author.login // "ghost"), path, line: (.line // .originalLine), outdated: .isOutdated,
      url: $c.url, first_line: one_line($c.body | clean)}] as $open
| [($reviews[0] // [])[] | select(.state == "CHANGES_REQUESTED" or .state == "APPROVED" or .state == "DISMISSED")]
  | group_by(.user.login) | map(sort_by(.submitted_at) | last)
  | map(select(.state == "CHANGES_REQUESTED")
        | {author: .user.login, review_url: .html_url, commit: .commit_id, at_head: (.commit_id == $sha),
           first_line: one_line(.body | clean)}) as $changes
| ([($reviews[0] // [])[] | {source: "review", author: (.user.login // "ghost"), url: .html_url, commit: .commit_id, body: (.body // "")}]
   + [($comments[0] // [])[] | {source: "comment", author: (.user.login // "ghost"), url: .html_url, commit: null, body: (.body // "")}]) as $items
| ($trusted | map(ascii_downcase)) as $tr
| ($p.author.login // "" | ascii_downcase) as $author
| candidates("review"; $items; $sha; $tr; $author; $allow_author) as $rc
| (if ($rc.at_head | length) == 0 then
     {state: "absent", reason: ((if $rc.stale > 0 then "no review receipt at this head; \($rc.stale) at other commits do not count" else "no review receipt at this head" end) + author_note($rc))}
   elif ($rc.at_head | length) > 1 then
     {state: "multiple", reason: "\($rc.at_head | length) receipt-bearing review comments at this head, expected exactly one",
      by: [$rc.at_head[].author]}
   else $rc.at_head[0] as $it | parse("review"; $it.body) as $x
     | if ($x.ok | not) then {state: "invalid", reason: $x.reason, by: [$it.author], url: $it.url}
       elif (review_valid($x.receipt; $x.body; $target; $sha) | not) then
         {state: "invalid", reason: "review receipt is malformed or inconsistent (key set, target, sha, verdict, counts)", by: [$it.author], url: $it.url}
       else {state: $x.receipt.verdict, verdict: $x.receipt.verdict, critical: $x.receipt.critical, issues: $x.receipt.issues,
             actionable: ($x.receipt.critical > 0 or $x.receipt.issues > 0), by: [$it.author], url: $it.url}
       end
   end) as $review
| candidates("proof"; $items; $sha; $tr; $author; $allow_author) as $pc
| (if ($pc.at_head | length) == 0 then
     {state: "absent", reason: ((if $pc.stale > 0 then "no proof receipt at this head; \($pc.stale) at other commits do not count" else "no proof receipt at this head" end) + author_note($pc))}
   elif ($pc.at_head | length) > 1 then
     {state: "multiple", reason: "\($pc.at_head | length) receipt-bearing comments at this head, expected exactly one", by: [$pc.at_head[].author]}
   else $pc.at_head[0] as $it | parse("proof"; $it.body) as $x
     | if ($x.ok | not) then {state: "invalid", reason: $x.reason, by: [$it.author], url: $it.url}
       elif (proof_valid($x.receipt; $target; $sha) | not) then
         {state: "invalid", reason: "proof receipt is malformed or inconsistent (key set, target, sha, verdict, evidence url)", by: [$it.author], url: $it.url}
       elif $evidence_error != "" then
         {state: "invalid", reason: "evidence run rejected: \($evidence_error)", by: [$it.author], url: $it.url}
       else {state: "proven", kind: $x.receipt.kind, evidence_url: $x.receipt.evidence_url, by: [$it.author], url: $it.url, receipt: $x.receipt}
       end
   end) as $proof
| (($pr2[0].headRefOid // $sha) as $now | if $now != $sha then {from: $sha, to: $now} else null end) as $moved
| (if $p.state == "MERGED" then ["merged", "row 1: the pull request is merged"]
   elif $p.state == "CLOSED" then ["closed", "row 2: the pull request is closed"]
   elif $moved != null then ["wait-ci", "head moved during the read: re-run against the new head"]
   elif $github == "dirty" or $github == "behind" then ["rebase-needed", "row 3: branch is \($github)"]
   elif $github == "draft" or $github == "unknown" then ["wait-ci", "row 4: hold, github state is \($github)"]
   elif ["absent", "invalid", "multiple"] | index($review.state) then ["needs-review", "row 5: review receipt is \($review.state)"]
   elif $review.verdict == "blocked" or $review.actionable then ["needs-repair", "row 6: review verdict \($review.verdict) with findings"]
   elif $ci == "red" or $github == "refused" then ["needs-repair", "row 7: ci red or github refuses the merge"]
   elif ($open | length) > 0 or ($changes | length) > 0 then ["address-threads", "row 8: unresolved threads or standing changes-requested reviews"]
   elif $ci == "pending" then ["wait-ci", "row 9: ci is still running"]
   elif $proof.state != "proven" then ["needs-prove", "row 10: proof receipt is \($proof.state)"]
   else ["merge-ready", "row 11: every condition holds at this head"] end) as $next
| [ (if $moved then "head moved from \($moved.from) to \($moved.to): receipts at the old head no longer count" else empty end),
    (if $p.state == "MERGED" then "pull request is merged" elif $p.state == "CLOSED" then "pull request is closed" else empty end),
    (if $github == "draft" then "pull request is a draft" else empty end),
    (if $github == "dirty" then "merge conflicts with the base branch" elif $github == "behind" then "branch is behind the base branch" else empty end),
    (if $github == "unknown" then "github has not computed the merge state yet" elif $github == "refused" then "github refuses the merge: blocked with red checks" else empty end),
    ($checks[] | select(.state == "red") | "ci red: \(.name) (\(.conclusion))"),
    ($checks[] | select(.state == "pending") | "ci pending: \(.name)"),
    ($open[] | "unresolved thread by \(.author) at \(.path):\(.line // 0)"),
    ($changes[] | "changes requested by \(.author)" + (if .at_head then "" else " (on an older commit)" end)),
    (if ["absent", "invalid", "multiple"] | index($review.state) then "review receipt \($review.state): \($review.reason)"
     elif $review.verdict == "blocked" then "review verdict is blocked"
     elif $review.actionable then "review verdict \($review.verdict) with \($review.critical) critical and \($review.issues) issues" else empty end),
    (if $proof.state != "proven" then "proof receipt \($proof.state): \($proof.reason)" else empty end)
  ] as $blocking
| {target: $target, sha: $sha, state: $p.state, github: $github, ci: $ci, ci_note: (if $ci == "none" then "no ci configured" else null end),
   ready: ($next[0] == "merge-ready"), next: $next[0], next_reason: $next[1], blocking: $blocking,
   checks: $checks, threads_open: $open, changes_requested: $changes,
   review: $review, proof: $proof, head_moved: $moved}
JQ
)

render() {
  jq -r '
    (if .ready then "READY" else "NOT READY: \(.blocking[0] // .next_reason)" end),
    "target  \(.target)", "head    \(.sha)", "state   \(.state)  github \(.github)  ci \(.ci)\(if .ci_note then " (" + .ci_note + ")" else "" end)",
    (.checks[] | select(.state != "pass") | "  check \(.state): \(.name) \(.conclusion) \(.url // "")"),
    (.threads_open[] | "  thread: \(.author) \(.path):\(.line // 0) \(.first_line)"),
    (.changes_requested[] | "  changes requested: \(.author) \(.review_url)"),
    "review  \(.review.state)\(if .review.by then " by " + (.review.by | join(",")) else "" end)\(if .review.reason then " (" + .review.reason + ")" else "" end)",
    "proof   \(.proof.state)\(if .proof.kind then " " + .proof.kind else "" end)\(if .proof.by then " by " + (.proof.by | join(",")) else "" end)\(if .proof.reason then " (" + .proof.reason + ")" else "" end)",
    "next    \(.next)  \(.next_reason)",
    (.blocking[] | "  - " + .)
  ' <<<"$1"
}

fetch_live() {
  local dir=$1 repo=$2 n=$3 owner=${2%%/*} name=${2#*/} raw
  raw=$(gh pr view "$n" --repo "$repo" --json number,state,isDraft,headRefOid,mergeable,mergeStateStatus,author,statusCheckRollup)
  if [ "$(jq -r '.state + "/" + .mergeStateStatus' <<<"$raw")" = "OPEN/UNKNOWN" ]; then
    sleep 5
    raw=$(gh pr view "$n" --repo "$repo" --json number,state,isDraft,headRefOid,mergeable,mergeStateStatus,author,statusCheckRollup)
  fi
  jq 'del(.statusCheckRollup)' <<<"$raw" > "$dir/pr.json"
  jq '.statusCheckRollup // []' <<<"$raw" > "$dir/checks.json"
  # shellcheck disable=SC2016  # graphql variables, not shell
  gh api graphql --paginate -F owner="$owner" -F repo="$name" -F n="$n" -f query='
    query($owner:String!,$repo:String!,$n:Int!,$endCursor:String){repository(owner:$owner,name:$repo){pullRequest(number:$n){
      reviewThreads(first:100,after:$endCursor){pageInfo{hasNextPage endCursor}
        nodes{isResolved isOutdated path line originalLine comments(first:1){nodes{author{login} body url}}}}}}}' \
    | jq -s '[.[].data.repository.pullRequest.reviewThreads.nodes[]]' > "$dir/threads.json"
  gh api --paginate "repos/$repo/pulls/$n/reviews?per_page=100" | jq -s 'add // []' > "$dir/reviews.json"
  gh api --paginate "repos/$repo/issues/$n/comments?per_page=100" | jq -s 'add // []' > "$dir/comments.json"
  gh pr view "$n" --repo "$repo" --json headRefOid > "$dir/pr2.json"
}

dir=""

main() {
  local target="" want_json=0 json_file="" trusted="" fixture="" order_repo="" allow_author=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) want_json=1 ;;
      --json-file) [ $# -ge 2 ] || usage; json_file=$2; shift ;;
      --trusted-actors) [ $# -ge 2 ] || usage; trusted=$2; shift ;;
      --fixture) [ $# -ge 2 ] || usage; fixture=$2; shift ;;
      --order-repo) [ $# -ge 2 ] || usage; order_repo=$2; shift ;;
      --allow-author-receipts) allow_author=true ;;
      -h|--help) usage ;;
      -*) usage ;;
      *) [ -z "$target" ] || usage; target=$1 ;;
    esac
    shift
  done
  [ -n "$target" ] || usage
  command -v jq >/dev/null || die "jq is required"
  [[ "$target" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[1-9][0-9]*$ ]] || die "target must look like owner/repo#123, got: $target"
  [[ "$trusted" =~ ^[A-Za-z0-9_,-]*$ ]] || die "trusted-actors must be a comma-separated list of github logins"
  local trusted_json
  trusted_json=$(jq -cn --arg t "$trusted" '$t | split(",") | map(select(length > 0))')
  [ "$trusted_json" != "[]" ] || die "--trusted-actors is required: name the accounts whose review and proof receipts count (anyone can comment on a pull request)"
  [[ -z "$order_repo" || "$order_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "order-repo must look like owner/repo, got: $order_repo"
  [ -n "$order_repo" ] || order_repo=${target%#*}

  if [ -n "$fixture" ]; then
    [ -d "$fixture" ] || die "fixture dir not found: $fixture"
    dir=$fixture
  else
    command -v gh >/dev/null || die "gh is required"
    dir=$(mktemp -d)
    trap 'rm -rf "${dir:-}"' EXIT
    fetch_live "$dir" "${target%#*}" "${target##*#}" || die "could not read $target from github (read-only gh calls failed)"
  fi

  local f
  for f in pr checks threads reviews comments; do
    [ -f "$dir/$f.json" ] || die "missing $dir/$f.json"
  done
  local pr2=/dev/null
  [ -f "$dir/pr2.json" ] && pr2=$dir/pr2.json

  if [ "$allow_author" != true ] && [ -z "$(jq -r '.author.login // empty' "$dir/pr.json")" ]; then
    die "the pull request author is unknown, so author receipts cannot be told apart; pass --allow-author-receipts to count them"
  fi

  decide() { # evidence-error: the verdict, with the proof receipt's evidence run judged by $1 ("" means accepted)
    jq -n --arg target "$target" --argjson trusted "$trusted_json" --argjson allow_author "$allow_author" \
      --arg evidence_error "$1" \
      --slurpfile pr "$dir/pr.json" --slurpfile checks "$dir/checks.json" --slurpfile threads "$dir/threads.json" \
      --slurpfile reviews "$dir/reviews.json" --slurpfile comments "$dir/comments.json" --slurpfile pr2 "$pr2" \
      "$DECIDE"
  }

  local result evidence_error=""
  result=$(decide "") || die "could not evaluate the pull request state (unexpected input shape)"
  if [ "$(jq -r '.proof.receipt.kind // ""' <<<"$result")" = aeon-skill ]; then
    # an aeon-skill receipt is shape-only: it names a run but nothing ties it to an order. a pull request
    # on an epoch/ branch has an order, so it needs the verify-run proof that is bound to it.
    command -v gh >/dev/null || die "gh is required to look up the pull request branch"
    local head_ref
    head_ref=$(gh api "repos/${target%#*}/pulls/${target##*#}" --jq .head.ref 2>/dev/null) \
      || die "could not read the pull request branch"
    if [[ "$head_ref" == epoch/* ]]; then
      evidence_error="a pull request on an epoch/ branch needs a verify-run proof; an aeon-skill receipt is not bound to the order"
      result=$(decide "$evidence_error") || die "could not evaluate the pull request state (unexpected input shape)"
    fi
  elif [ "$(jq -r '.proof.receipt.kind // ""' <<<"$result")" = verify-run ]; then
    command -v gh >/dev/null || die "gh is required to look up the evidence run"
    evidence_error=$(bash "$HERE/epoch-evidence.sh" check "$target" "$(jq -r .sha <<<"$result")" \
      "$(jq -c .proof.receipt <<<"$result")" "$order_repo" "$(jq -r '.proof.by[0]' <<<"$result")" 2>&1 >/dev/null) \
      || { evidence_error=${evidence_error:-evidence check failed}; evidence_error=$(printf '%s' "$evidence_error" | tr '\n' ' ' | cut -c1-300); }
    if [ -n "$evidence_error" ]; then
      result=$(decide "$evidence_error") || die "could not evaluate the pull request state (unexpected input shape)"
    fi
  fi

  [ -z "$json_file" ] || printf '%s\n' "$result" > "$json_file"
  if [ "$want_json" -eq 1 ]; then printf '%s\n' "$result"; else render "$result"; fi
  [ "$(jq -r .ready <<<"$result")" = true ]
}

main "$@"
