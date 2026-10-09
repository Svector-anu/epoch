# epoch

**epoch is your engineer.**

you hand it a goal, or a github issue, and a repo. it reads the code, plans the change, writes it, opens a pull request, has the pr reviewed, fixes what the review finds, runs the checks, and tells you when the pr is ready to merge. you read one pr and press merge.

it keeps its own notes in plain files, so it can pause, wait for ci, or pick up the next day without you re-explaining anything. it does not merge, and it does not touch anything you did not point it at.

epoch lives inside your own [aeon](https://github.com/aeonfun/aeon) instance: your repo, your github actions, your keys. nothing runs on our side and there is nothing to install on your machine.

## what it does

- **understands the repo.** it reads the code and the repo's own working rules (`AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`) and writes a map of what is there.
- **plans in small pieces.** a goal becomes one or more work orders: goal, scope, acceptance, the exact commands that verify it, what is forbidden.
- **builds one order at a time.** a throwaway checkout, a branch named `epoch/<order>`, the smallest change that satisfies the order, its verify commands run before anything is pushed, one pull request.
- **reviews with fresh eyes.** a separate run reads the diff at one exact commit, re-runs what the pr claims, and posts one review.
- **repairs once.** if the review finds something, one bounded repair pass. if it is still actionable after that, epoch stops and tells you why instead of looping.
- **proves it.** it runs the work order's verify commands in a clean, read-only github actions run at that same commit.
- **watches the pr.** it reads github state, ci, open review threads and the review and proof records, and says what comes next.
- **resumes.** every project has a handoff file. a fresh run that reads only that file knows what to do next.

## a real run, in 7 steps

1. you start it with a goal (`fix the flaky retry test in the sync job`) or an issue (`issue:owner/repo#12`).
2. epoch classifies the work (`task`, `fix`, `feature` or `project`), then `epoch-spec` writes the map, a spec when the work needs one, the work orders and a handoff.
3. `epoch-build` takes the first order, makes the change on its own branch, runs the order's verify commands, and opens one pr.
4. `epoch-review` reviews the pr at its pinned commit and posts one review with a verdict.
5. if the verdict asks for changes, `epoch-build` makes the one repair pass. a new commit means the old review and proof no longer count, so review runs again on the new head.
6. `epoch-prove` runs the order's verify commands in a clean actions run at the final commit, and `epoch-watch` checks everything at that commit: github state, ci, threads, review, proof.
7. epoch tells you the pr is ready, with the link and commit. you merge. if anything is stuck, it says what and what unblocks it.

each run of `epoch` moves a project forward by at most one stage. run it again to advance, or put it on a schedule (see below).

## where it lives, and what it remembers

epoch is a set of skills in your aeon repo, run by your github actions. what it remembers is ordinary files in the same repo:

```
memory/topics/<project>/map.md          what the repo is and how a change here is verified
memory/topics/<project>/spec.md         what success means (features and projects)
memory/topics/<project>/orders/<id>.md  one work order per unit
memory/topics/<project>/handoff.md      where the project stands and the one next action
memory/topics/<project>/conductor.json  which projects are active, and their phase
memory/candidates/<id>.json             one queue entry per unit, with its state
memory/logs/<date>.md                   what each run did
```

the pull request is the other half. the review and proof receipts are a github review and a comment on the pr itself, so they sit next to the code they are about.

## how to start

install the pack into your aeon repo (see requirements first):

```
bin/install-skill-pack Svector-anu/epoch
```

skills land disabled and run only when dispatched. hand it a goal:

```
gh workflow run aeon.yml -f skill=epoch -f var="fix the flaky retry test in the sync job"
```

or hand it an issue:

```
gh workflow run aeon.yml -f skill=epoch -f var="issue:owner/repo#12"
```

then keep it moving, check on it, or pick a paused project back up:

```
gh workflow run aeon.yml -f skill=epoch                                  # advance every active project one step
gh workflow run aeon.yml -f skill=epoch -f var="status"                  # print where each project stands, change nothing
gh workflow run aeon.yml -f skill=epoch -f var="resume:<project>"        # re-read the handoff, then advance that project
```

to have it advance on its own, schedule the conductor in your `aeon.yml`. a sensible starting point is `*/30 * * * *`. epoch ships it off: you turn it on when you trust it. the other skills (`epoch-spec`, `epoch-build`, `epoch-review`, `epoch-prove`, `epoch-watch`) are dispatched by the conductor and can also be run by hand; each one's `var` is documented at the top of its `SKILL.md`.

## requirements

- an aeon instance recent enough to have `scripts/dev-loop-review.sh` and `scripts/dev-loop-proof.sh`. a fork made through [aeon connect](https://www.aeon.fun/connect) works.
- `GH_GLOBAL`: a github token that can read the repos you point epoch at, push branches, write pull requests and dispatch workflows. it is the one secret epoch asks for.
- whatever model credential your instance already uses.
- for the prove stage, three pieces that are being proposed to aeon upstream: the `verify-run` receipt kind in `scripts/dev-loop-proof.sh`, the evidence check in `scripts/epoch-evidence.sh`, and `.github/workflows/epoch-verify.yml`. until they are merged, copy them from this pack's `upstream/` folder into your aeon repo and commit them. they go together: the script and the workflow agree on how a run is titled.

  ```
  git clone https://github.com/Svector-anu/epoch /tmp/epoch
  cp /tmp/epoch/upstream/scripts/dev-loop-proof.sh /tmp/epoch/upstream/scripts/epoch-evidence.sh scripts/
  cp /tmp/epoch/upstream/.github/workflows/epoch-verify.yml .github/workflows/
  ```

  the copy of `dev-loop-proof.sh` is aeon's own script plus the new receipt kind; the existing `aeon-skill` kind is unchanged. if any piece is missing, `epoch-prove` stops with `PROVE_UNSUPPORTED` and posts nothing. a proof made before you updated (a run titled by dispatch id only) no longer counts; run `epoch-prove` again.
- to prove prs in a repo other than your aeon repo, that repo needs `.github/workflows/epoch-verify.yml` on its default branch too. `epoch-prove` refuses a pr whose copy of that file differs from the default branch's.

## how it knows it is done

a model saying "looks good" is not evidence, so review and proof are receipts: one line in a github review or comment, bound to one 40-character commit.

```
<!-- aeon-review:{"schema":1,"target":"owner/repo#12","sha":"<40 hex>","verdict":"approve-ready","critical":0,"issues":0} -->
<!-- aeon-proof:{"schema":1,"target":"owner/repo#12","sha":"<40 hex>","kind":"verify-run","order":"<order id>","evidence_run_id":123,"evidence_url":"https://github.com/owner/repo/actions/runs/123","verdict":"proven"} -->
```

`scripts/dev-loop-review.sh` and `scripts/dev-loop-proof.sh` re-read the comment from github and check the commit, the target and the shape. nothing is trusted from a file a skill wrote locally. push another commit and the commit changes, so both receipts stop counting until the new head is reviewed and proven again.

the proof receipt points at an actions run. `epoch-prove` takes the verify commands from the work order in your aeon repo (found by the pr's `epoch/<order>` branch name), never from the pr, runs them through `epoch-verify.yml` (read-only, no secrets), and posts the receipt only if the run's log shows every command with `exit=0` at the pinned commit.

the gate does not take the receipt's word for the run. it reads the run from github and requires: a successful `workflow_dispatch` run of `epoch-verify.yml` at the pinned commit, dispatched by the account that posted the receipt; a workflow file identical to the default branch's copy; a run title that carries the sha256 of the commands it ran, equal to the sha256 of the `VERIFY` block of the order on the default branch; and a pr branch named `epoch/<order>`. so a green run of some other command, or of an edited workflow, is not proof of the order.

`epoch-watch` calls a pr merge-ready only when all of these hold at the same commit:

1. the pr is open and not a draft
2. github is willing to merge it
3. a review receipt exists and its verdict is neither `blocked` nor an actionable `discussion-needed`
4. a proof receipt exists
5. no ci check is red or still pending
6. no unresolved review thread and no standing requested-changes review

github saying "mergeable" is one condition of six, not the answer.

## works on any repo: epoch-check

the "is this pr really ready" check does not need aeon. `scripts/epoch-check.sh` and the github action in this repo look at one pull request and say `READY` or `NOT READY` at its current commit, naming what is missing: failing ci by name, open review threads, a review or proof receipt that is absent or belongs to an older commit.

```yaml
- uses: Svector-anu/epoch@main
  with:
    pr: ${{ github.event.pull_request.number }}
```

any agent, or a person, can post a valid receipt, so you can adopt the check without the rest of epoch. you name the accounts whose receipts count with `trusted-actors` (required), and receipts from the pr's own author are ignored unless you allow them. the format and the ten-line workflow are in [docs/epoch-check.md](docs/epoch-check.md).

## trust model

what the gate enforces, at one head commit:

- a receipt counts only if a trusted account posted it. in `epoch-check` the list of accounts is required; in the aeon gates it is the account behind the instance token.
- a receipt counts only at the exact commit it names. a new push voids both. duplicates void themselves: exactly one per kind per commit.
- the proof run has to be the pinned `epoch-verify` workflow, dispatched by the account that posted the receipt, running the hash of the commands in the order on the default branch. the pr can edit its own code but not the order or the verifier that judge it.
- the order is found by the branch name `epoch/<order>`, from a branch in the same repo, never from the pr body.

what it assumes:

- one github token per instance means one account does the building, the reviewing and the proving. the receipts then show that the pipeline ran, not that three independent parties agreed. use separate accounts for build and for review and proof if you want that, and keep `allow-author-receipts` off.
- a human reads the pr and presses merge. the gate says what is missing; it does not decide to merge.
- nothing else merges epoch branches. an auto-merge skill, a merge queue rule or a bot that merges green prs on its own will not look at these receipts. keep epoch branches out of their paths.
- the default branch is protected from the accounts that build. whoever can change the order or `epoch-verify.yml` there can change what counts.
- the commands in an order are the ones you want run. a passing run proves they passed, not that they test the right thing.

what it does not do:

- it does not make the pipeline tamper-proof. a stolen token can post a receipt, dispatch a run and edit its own comments.
- it does not read the code. a review receipt is one reviewer's verdict, not a guarantee.
- it does not check `aeon-skill` receipts beyond their shape.
- it does not cover prs from forks, and it does not stop a person with write access from merging by hand.

## limits, said plainly

- **one repair pass.** if review is still actionable after it, the order is blocked and you decide.
- **two attempts per stage.** a stage that fails twice at the same commit blocks the project instead of retrying.
- **one unit in flight per project, one stage per run.** it is steady, not fast.
- **no rebase stage.** if the base moves under a pr, epoch blocks and says so.
- **prove runs only what the order lists.** it does not guess commands from the diff or from ci config, and it refuses prs from forks, branches not named `epoch/<order>`, prs that edit `epoch-verify.yml`, and orders with no verify commands. a refused proof means the pr cannot become merge-ready.
- **same-family review is weaker.** if build and review ran on the same model family, the review says so. a fresh context with no access to the builder's reasoning is the independence you get.
- **text from issues and prs is data.** epoch reads it for the goal and the findings and never takes instructions from it.
- **nothing merges itself.** not the conductor, not any other skill here.
- **it is early.** treat the first runs on a repo as supervised. questions, or something broke? contact us at anu@aeon.fun.

## tuning it

the skills are prompts in `skills/*/SKILL.md`: edit them in your own repo. `STRATEGY.md` steers what `epoch-spec` thinks is worth doing. keep the receipt formats and the gate calls as they are, since those are what make the receipts checkable.

## contact

more info: anu@aeon.fun

## license

mit.
