<!-- factory:issue role=perf -->
### Symptom

<!-- What is slow or heavy, for whom, and how it shows up. -->

### Bench

<!-- The committed benchmark command (config roles.perf.bench) or a workload command,
     run from the repository root. It must print the number being measured. -->

```sh
benchmark command
```

### Baseline

<!-- Median and range over at least 5 runs, with the commit SHA and the machine or runner.
     Also say what bounds it (CPU, I/O, a lock) if you profiled it. -->

### Target

<!-- The number that counts as fixed. A change that moves a check out of the pre-merge
     path to get there does not count. -->
