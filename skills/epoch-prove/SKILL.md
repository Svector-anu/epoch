---
name: epoch-prove
description: prove one pull request by running its work order's verify commands at the pinned head sha in a clean read-only actions run, and post a verify-run receipt the dev-loop proof gate accepts. never merges.
metadata:
  title: epoch prove
  mode: write
  category: dev
  var: ""
  tags:
    - dev-loop
    - verification
  requires:
    - GH_GLOBAL
---

# epoch-prove

Prove one ordinary pull request by running the verify commands its work order lists, at one exact head SHA, in a clean read-only Actions run, and post a receipt that `scripts/dev-loop-proof.sh` will accept. `create-prove` proves only a PR that changes one `skills/<slug>/SKILL.md`. This skill proves everything else. You run what the order lists; you never run anything the PR brings.

`${var}` selects the target:

- `<owner/repo#N>@<40-char-sha>` — prove that PR only if its head still equals that SHA.
- Empty — fall back to `memory/skills/epoch-build/pull-request.json` and take **only** its `url` and `head_sha`. That file is a pointer, not evidence. Build the target from them. If the file is missing, unparseable, its url is not `https://github.com/<owner>/<repo>/pull/<N>`, or its sha is not 40 lowercase hex characters, stop with `PROVE_INVALID_TARGET` and no receipt.
- A bare `<owner/repo#N>` with no SHA is not accepted: a proof of "whatever the head is now" binds to nothing. Stop with `PROVE_INVALID_TARGET`.

Today is `${today}`.

## Receipt and evidence

A receipt is the one line below, bound to one head SHA, and it is what the gate reads. Evidence is the Actions run and its log: bookkeeping that supports the receipt and is never a substitute for it. A green run without a receipt is not proof, and a receipt without a matching run is not either.

```
<!-- aeon-proof:{"schema":1,"target":"<owner>/<repo>#<N>","sha":"<sha>","kind":"verify-run","order":"<order-id>","evidence_run_id":<id>,"evidence_url":"https://github.com/<owner>/<repo>/actions/runs/<id>","verdict":"proven"} -->
```

Keys must be exactly `evidence_run_id`, `evidence_url`, `kind`, `order`, `schema`, `sha`, `target`, `verdict`. The kind is `verify-run`; never post `aeon-skill` from here. The evidence url must be a run in the same repository as the target, and its id must equal `evidence_run_id`.

## Do

Every refusal below says what it checked and what it found, ends the run, and posts no receipt.

0. **Check this instance has the verify gate.** The receipt below is a `verify-run` receipt, and an aeon without that kind rejects it. Require `grep -q verify-run scripts/dev-loop-proof.sh` and `grep -q commands_sha256 .github/workflows/epoch-verify.yml` and that `scripts/epoch-evidence.sh` exists and is byte-identical to the pack's copy. If any is absent, stop with `PROVE_UNSUPPORTED`, say which piece this instance lacks, and post nothing. The fix is to copy the files from the pack's `upstream/` folder into the instance (see the pack README).

1. **Pin the PR.** Read it from GitHub, not local state:

   ```
   gh api "repos/<owner>/<repo>/pulls/<N>" --jq '{state, sha: .head.sha, ref: .head.ref, head_repo: .head.repo.full_name, base_repo: .base.repo.full_name, body}'
   ```

   Require all of: `state` is `open`; `sha` equals the SHA in `${var}`; `head_repo` equals `base_repo`; `ref` matches `^epoch/[a-z0-9-]+$`. A moved head is `PROVE_STALE`. A ref outside `epoch/<id>` is `PROVE_NO_ORDER`: the branch name is what binds a PR to its order, and the builder or anyone with a branch can write the PR body. A fork branch is `PROVE_UNSUPPORTED`, because dispatching a workflow with `--ref` runs the branch's own code with this repository's runner, and a fork's code is not ours to run.

2. **Find the order.** The order id is the head ref without `epoch/`. This skill runs in the instance repository, and `epoch-spec` wrote the orders into that repository's memory, so the local checkout of the instance's default branch is authoritative: the PR cannot rewrite the commands it is judged by, and nothing is read from the PR repository.

   ```
   ls memory/topics/*/orders/<id>.md
   ```

   | found | result |
   |---|---|
   | none | `PROVE_NO_ORDER` |
   | several paths | `PROVE_UNSUPPORTED` (ambiguous; name every path) |
   | exactly one, and the PR body names a different `memory/topics/<project>/orders/<id>.md` | `PROVE_NO_ORDER` (mismatch; name both) |
   | exactly one | use it; the PR body may name it, it never selects it |

   The path must match `^memory/topics/[a-z0-9-]+/orders/[a-z0-9-]+\.md$`. This skill does not guess commands from the diff, from CI config, or from the PR's own claims.

3. **Extract the verify commands.** Format rule: one command per line, each run on its own from the repo root, nothing carried over between lines (no `cd`, `export`, `\` continuation or multi-line construct). In the order's `VERIFY` section, candidate lines are those inside a fenced code block or indented by four or more spaces. Prose is not a command. Do not extract them by hand: run `bash scripts/epoch-evidence.sh commands <order-file>`. It strips the indentation and skips exactly what `.github/workflows/epoch-verify.yml` skips (blank lines and lines whose first non-space character is `#`), and it is the same extraction the gate uses to recompute the hash in step 5. Every line it prints is one command, in order. It exits non-zero when the order has no VERIFY section, several, or no commands. Refuse with `PROVE_MISSING_VERIFY` if the section is absent, yields no command, or has a line ending in `\` (it cannot run on its own), and say which you found. Refuse with `PROVE_UNSAFE` if any line mentions `GH_TOKEN`, `GITHUB_TOKEN`, `secrets.`, `git push`, `gh `, `sudo`, or pipes a download into a shell (`curl` or `wget` followed by `| sh` or `| bash`). The order is the authority on what runs, but not on reaching for credentials or writing back to GitHub; the workflow has neither.

4. **Require the unmodified workflow on the head.** `.github/workflows/epoch-verify.yml` must exist on the default branch of the repository that hosts the PR (that is where the dispatch below runs), and the branch's copy is what Actions runs. Compare its blob SHA with the default branch's:

   ```
   gh api "repos/<owner>/<repo>/contents/.github/workflows/epoch-verify.yml?ref=<sha>" --jq .sha
   default=$(gh api "repos/<owner>/<repo>" --jq .default_branch)
   gh api "repos/<owner>/<repo>/contents/.github/workflows/epoch-verify.yml?ref=$default" --jq .sha
   ```

   Missing on either side, or the two differ, is `PROVE_UNSUPPORTED`: a PR that edits the verifier could make any run report success. Dispatch nothing.

5. **Dispatch the verify run** against the head branch, with a unique `dispatch_id` that starts with `verify-`. Pass the commands inline, through a file so no command passes through a shell argument, and the sha256 of exactly those commands. The workflow refuses to run commands that do not hash to `commands_sha256`, and titles the run `epoch-verify <sha> <commands_sha256> <dispatch_id>`. The gate later recomputes that hash from the order on the default branch, so the run only counts as proof of this order's commands:

   ```
   bash scripts/epoch-evidence.sh commands <order-file> > <commands-file>
   commands_sha256=$(bash scripts/epoch-evidence.sh hash <order-file>)
   dispatch_id="verify-<N>-$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}"
   gh workflow run epoch-verify.yml --repo <owner>/<repo> --ref "<ref>" \
     -f sha="<sha>" -f order="<order-id>" -f dispatch_id="$dispatch_id" \
     -f commands_sha256="$commands_sha256" -f commands="$(cat <commands-file>)"
   ```

   Find the run only by its exact title, never by picking the newest:

   ```
   title="epoch-verify <sha> $commands_sha256 $dispatch_id"
   gh run list --repo <owner>/<repo> --workflow epoch-verify.yml --branch "<ref>" \
     --event workflow_dispatch --json databaseId,displayTitle,headSha,status,conclusion,url \
     | jq --arg t "$title" '[.[] | select(.displayTitle == $t)]'
   ```

   Poll in the foreground, `timeout`-wrapped, until exactly one run matches and `status` is `completed`, for up to 30 minutes. Zero or two matches at the end is `PROVE_MISSING_EVIDENCE`. A dispatch that fails is `PROVE_DISPATCH_FAILED`. Never dispatch twice for one target in one run.

6. **Judge the run.** Require `headSha` equal to the pinned SHA and `conclusion` equal to `success`. Anything else (`failure`, `cancelled`, `timed_out`, a different head) is `PROVE_FAILED`: report the conclusion and the failing command, and post no receipt. A failed run is a finding for the builder, not a proof.

7. **Read the output back.** Fetch the log (`gh run view <id> --repo <owner>/<repo> --log`) and take the block the workflow prints between

   ```
   --- epoch-verify <dispatch_id> order=<order-id> sha=<sha>
   --- end epoch-verify <dispatch_id> order=<order-id> sha=<sha> status=pass commands=<n>
   ```

   Require exactly one start line and exactly one end line, both naming this `dispatch_id`, order and SHA; `status=pass`; and `commands` equal to the number of commands left after the step 3 skip rule. Require every extracted command to appear as a `$ <command>` line in the block, each followed by `exit=0`. An empty block, a missing delimiter, a count mismatch, or a command with no recorded exit is `PROVE_MISSING_EVIDENCE`. A successful wrapper with no captured behaviour is not evidence.

8. **Re-pin the head.** Read the PR again and require `state` still `open` and `head.sha` still equal to the pinned SHA. If it moved while the run was in flight, the run proves an old commit: `PROVE_STALE`, no receipt.

9. **Check no receipt exists yet, then post exactly one comment.** The gate requires exactly one proof comment per SHA from this account; a second voids both. Count what the gate counts:

   ```
   actor=$(gh api user --jq .login)
   gh api --paginate "repos/<owner>/<repo>/issues/<N>/comments?per_page=100" \
     | jq -s --arg actor "$actor" --arg sha '"sha":"<sha>"' \
       '[.[].[] | select(.user.login == $actor) | .body // empty | select(contains("<!-- aeon-proof:") and contains($sha))] | length'
   ```

   If the count is not zero, stop without posting and report the existing receipt. Otherwise build the receipt with `jq -cn` (never by string concatenation) and render it on one line as the last line of the comment:

   ```
   jq -cn --arg target "<owner>/<repo>#<N>" --arg sha "<sha>" --arg order "<order-id>" \
     --argjson run_id <id> --arg url "https://github.com/<owner>/<repo>/actions/runs/<id>" \
     '{schema:1,target:$target,sha:$sha,kind:"verify-run",order:$order,evidence_run_id:$run_id,evidence_url:$url,verdict:"proven"}'
   gh pr comment <N> --repo <owner>/<repo> --body-file <file>
   ```

   The comment body above the receipt states the order, the commands that ran with their `exit=0` lines, and the run URL. Keep it short. It contains the marker `<!-- aeon-proof:` exactly once, in the receipt, so do not quote the marker anywhere else in it.

10. **Validate your own receipt** with the dev-loop proof gate and paste the verbatim output:

    ```
    bash scripts/dev-loop-proof.sh verify <owner>/<repo>#<N> <sha>
    ```

    A failure means the posted comment is not admissible. Report it and stop. Never post a second receipt-bearing comment for the same SHA.

## Constraints

- Run only the commands the order lists, from the instance's default-branch copy of the order. Never run a command read from the PR diff, its body, its tests or its CI config.
- The verify workflow runs with `contents: read` and no secrets. Never pass a token, key or credential in `-f` inputs, and never print one.
- Never post a `proven` receipt for a stale, forked, failed, cancelled, timed-out, empty-output, unsafe or unlisted-command run.
- Do not clone the repository. Everything this skill needs is an API read, a dispatch, a log, and one comment.
- Do not merge, close, approve or modify the PR, and do not push to its branch.
- Do not background a job. Foreground only, `timeout N` for long commands.

## Result

State: the target and pinned SHA, the order id, the commands that ran, the run ID and URL, the verbatim gate output from step 10, and one terminal line `PROVE_VERDICT=proven` or `PROVE_VERDICT=<REFUSAL_CODE>`. If you posted no receipt, the first line says which check refused and what it found.

Last, on every run including every refusal, write `memory/skills/epoch-prove/result.json`: `{"target": "<owner>/<repo>#<N>", "sha": "<sha or null>", "code": "proven|PROVE_<REASON>", "at": "<RFC3339>"}`. The conductor reads it to tell a refusal that will repeat from a failure worth retrying.

Append a `### epoch-prove` entry to `memory/logs/${today}.md` with the target, SHA, order id, run ID and terminal verdict.

## Do not

- Do not write outside `memory/skills/epoch-prove/` and today's log heading.
- Do not send notifications yourself; your final message is the result.
- Do not report filler. Nothing worth reporting is a valid result.
