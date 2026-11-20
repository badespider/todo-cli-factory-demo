<!-- factory:issue role=bug-fix -->
### Summary

<!-- What is wrong: observed behaviour vs expected behaviour, in one or two sentences. -->

### Repro

<!-- One self-contained shell command, run from the repository root, that exits non-zero
     while the bug exists and exits 0 once it is fixed. scripts/verify-fix.sh runs this
     block from the issue's ORIGINAL text, so edits made after filing are ignored.
     It runs with a clean environment: no tokens, a fresh HOME and TMPDIR. -->

```sh
command that fails while the bug exists
```

expect: a substring of the failing output that proves this is the bug and not some other failure

### Severity

<!-- Set by a human from the project's rubric. Agents leave "unrated". -->
unrated

### Escape of

<!-- If this is another case of a recently closed fix, link it (#N) and add the label `escape`. -->
none
