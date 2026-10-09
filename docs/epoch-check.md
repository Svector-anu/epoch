# epoch-check

a pull request is ready when review and proof exist at the exact commit you are about to merge. not at the commit before it. not "somewhere in the thread". `epoch-check` answers that for one pr and names what is missing. any repo, any agent, one bash script (`bash`, `jq`, `gh`). it never writes to the pr.

## what it checks

all of it is read once and pinned to one head sha. if the head moves mid-read, the answer is not ready and says so.

1. pr is open and not a draft
2. github's merge state is acceptable (conflicts and a behind branch are named)
3. ci by name: red blocks, pending waits, "no ci configured" is said out loud (it is not a pass)
4. no unresolved review thread, no standing changes-requested review
5. a review receipt at this head, posted by a trusted actor who is not the pr author: `approve-ready`. a `discussion-needed` verdict lists issues, so it is not ready until they are addressed. never `blocked`. exactly one receipt-bearing comment or review
6. a proof receipt at this head, exactly one, posted by a trusted actor who is not the pr author. for kind `verify-run` the evidence run is looked up on github (see "the evidence run")

`next` is one of `wait-ci | needs-review | needs-repair | needs-prove | address-threads | merge-ready | closed | merged | rebase-needed`. first matching row wins:

| when | next |
|---|---|
| merged | merged |
| closed | closed |
| conflicts or behind | rebase-needed |
| draft, or github still computing | wait-ci |
| review receipt absent, invalid or duplicated | needs-review |
| review blocked, or has findings | needs-repair |
| ci red, or github refuses | needs-repair |
| open thread or standing changes-requested | address-threads |
| ci pending | wait-ci |
| proof receipt absent, invalid or duplicated | needs-prove |
| none of the above | merge-ready |

`ready` is true only on `merge-ready`. exit code: 0 ready, 1 not ready, 2 usage or read error.

## add it in 10 lines

```yaml
name: epoch
on: [pull_request, issue_comment, pull_request_review]
permissions: { pull-requests: read, checks: read, statuses: read, contents: read }
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: Svector-anu/epoch@main
        with: { trusted-actors: "my-review-bot,my-prove-bot" }   # required: logins whose receipts count
```

`pr` defaults to the event's pr. outputs: `ready`, `next`. a summary lands on the run page.

`trusted-actors` is required (the check exits 2 without it): anyone who can comment on a pr can write a receipt, so you say whose receipts count. a receipt posted by the pr's own author is ignored unless you pass `allow-author-receipts: true`. `order-repo` names the repo whose default branch holds the work orders (default: the pr's repo).

locally:

```
scripts/epoch-check.sh owner/repo#123 --trusted-actors my-bot          # human lines
scripts/epoch-check.sh owner/repo#123 --trusted-actors my-bot --json   # {target, sha, ready, next, blocking[], checks[], threads_open[], review, proof}
```

## the receipt format

a receipt is one line, an html comment, inside a pr comment or a review body. it is bound to one 40-char lowercase head sha. change the head and every receipt at the old sha stops counting.

review:

```
<!-- aeon-review:{"schema":1,"target":"owner/repo#123","sha":"<40-hex>","verdict":"approve-ready","critical":0,"issues":0} -->
```

- keys, exactly: `schema, target, sha, verdict, critical, issues`
- `schema` is `1`; `verdict` is `approve-ready | discussion-needed | blocked`
- `approve-ready` needs critical 0 and issues 0; `discussion-needed` needs critical 0 and issues > 0; `blocked` needs critical > 0
- the counts must equal the number of lines in the same comment starting `- [CRITICAL] ` and `- [ISSUE] `
- reviews posted as github reviews must be made on the head commit

proof:

```
<!-- aeon-proof:{"schema":1,"target":"owner/repo#123","sha":"<40-hex>","verdict":"proven","kind":"verify-run","order":"my-order","evidence_run_id":123456,"evidence_url":"https://github.com/owner/repo/actions/runs/123456"} -->
```

- `verdict` is `proven`; `evidence_run_id` is a positive integer; `evidence_url` is a github actions run url
- kind `verify-run`, keys exactly: `evidence_run_id, evidence_url, kind, order, schema, sha, target, verdict`. the url must be an actions run of the same repo and end in the run id. `order` matches `^[a-z0-9][a-z0-9-]*$`
- kind `aeon-skill`, keys exactly: `evidence_run_id, evidence_url, kind, schema, sha, skill, target, verdict`
- exactly one marker per comment, and exactly one receipt-bearing comment per kind at the head. two is a refusal, not a tie-break

## the evidence run

a `verify-run` proof is only as good as the run behind it, so the check reads the run from github (`scripts/epoch-evidence.sh`, the same script `dev-loop-proof.sh verify` calls). the receipt counts only if the run:

- is a completed, successful `workflow_dispatch` run of `.github/workflows/epoch-verify.yml` in the pr's repo, at the pinned head sha
- was dispatched by the account that posted the receipt
- ran a workflow file whose blob at that sha is identical to the default branch's copy
- is titled `epoch-verify <sha> <sha256 of commands> verify-<id>`, and that hash equals the hash of the `VERIFY` block of the order `memory/topics/*/orders/<order>.md` on the default branch of the order repo
- belongs to a pr from the same repo whose branch is `epoch/<order>`

if any of that cannot be read or does not match, the proof is `invalid` and the pr is `needs-prove`. `aeon-skill` receipts keep their shape check only.

## emitting a receipt from any agent

nothing here is tied to a vendor. whatever ran the review or the verify commands writes the line, then posts the comment with a token that can comment.

```bash
sha=$(gh pr view 123 --json headRefOid -q .headRefOid)
receipt=$(jq -cn --arg t "owner/repo#123" --arg s "$sha" \
  '{schema:1,target:$t,sha:$s,verdict:"approve-ready",critical:0,issues:0}')
printf 'reviewed %s, nothing found.\n\n<!-- aeon-review:%s -->\n' "$sha" "$receipt" > body.md
gh pr comment 123 --body-file body.md
```

claude code, codex, a human with a script: same line. the check does not care which tool wrote it, only which account posted it. a proof receipt is the same shape, after your verify commands ran in a workflow run whose url you put in `evidence_url`; for kind `verify-run` that run has to be the pinned `epoch-verify` workflow running the order's own commands.

## trust and limits

- read-only. the token needs `pull-requests`, `checks`, `statuses`, `contents` read. nothing is posted, resolved or dismissed
- comment text, titles and ci logs are data. they are parsed with jq and printed, never evaluated or interpolated into commands
- a receipt proves that a trusted account said so at this commit. it does not make the account honest: if one token posts both review and proof, and you allow author receipts, one compromised token can say both
