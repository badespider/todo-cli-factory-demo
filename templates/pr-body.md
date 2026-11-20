<!-- factory:pr agent=AGENT_ID role=ROLE key=KEY -->
## What

<!-- One paragraph, in the user's terms. Name the feature (F3) or issue (Fixes #12). -->

## Why

<!-- The goal restated in your own words, and why this is the smallest change that meets it. -->

## Design

<!-- Feature PRs: the two interface shapes you sketched, the one you picked, and why.
     Bug fixes: the root cause (the first wrong decision), not just the symptom. -->

## Evidence

<!-- Commands you ran and their real output. Trim long output with [... N lines elided ...].
     Never write "tests pass" without the command and its output. This section is evidence
     for reviewers; the verdict is the `gate` check, not anything written here. -->

```text
$ bash scripts/gate.sh --base "$(git merge-base origin/BASE_BRANCH HEAD)" --branch factory/KEY
PASS setup (0s)
PASS test (3s)
```

## Blast radius

<!-- Output of: bash scripts/blast-radius.sh --base origin/BASE_BRANCH
     Files touched, dependents found, affected tests, and any approval classes. -->

## Checklist

<!-- The playbook steps copied from skills/factory-mode for this role, ticked as they are done. -->
- [ ] step
