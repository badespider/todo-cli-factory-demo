# Harness wrappers

`harness_cmd` in `factory.config.yaml` is the one value that picks the harness. `run-agent.sh` splits it on whitespace (quotes are not interpreted) and appends the prompt as the last argument. Anything that needs more than that, such as setting up a login before the harness starts, goes in a small wrapper in this folder.

Every file here is a `rules-change` path: changing one needs an operator `approve <sha>` comment, like the scripts that judge the agents.

## How run-agent.sh runs a wrapper

```yaml
harness_cmd: bash factory/harness/auth-file.sh <harness command and flags...>
```

- argv is `bash`, `factory/harness/auth-file.sh`, the harness command and its flags, then the prompt.
- When argv[0] is `bash` or `sh` and argv[1] is a relative path, run-agent.sh resolves argv[1] against the **main checkout**, not the agent's worktree. A PR branch that edits the wrapper can't change the copy that runs; the base branch's copy always does. Put nothing between the shell and the wrapper path: with a shell option first (`bash -e factory/harness/x.sh ...`), argv[1] is that option, so the path is neither resolved against the main checkout (a run in a worktree would run that worktree's copy) nor looked through by the preflight.
- The preflight, which runs before anything is locked or claimed, looks through the wrapper: it checks that the shell, the wrapper file in the main checkout and the harness command after the wrapper (argv[2], or argv[3] when a `--` follows the wrapper) are all there. In CI, a missing harness command is installed with `harness_install` first. Anything still missing exits 2. A dry run only warns about it. A wrapper with nothing after it, or only options of its own, counts as the harness itself; then only the shell and the wrapper are checked.
- The lines of the `FACTORY_AGENT_ENV` secret (or file) are exported for the harness process only. A wrapper is part of that process, so it sees them; run-agent.sh's own git, gh and helper calls don't.
- The wrapper ends with `exec "$@"`: the harness replaces it, keeps its process id (so run-agent.sh's timeout and signals reach it), and its exit code is the run's.

## `auth-file.sh`: a login that is a file

Some harnesses log in on CI from an environment variable (an API key); those need no wrapper, only a `KEY=VALUE` line in `FACTORY_AGENT_ENV`. Others read a login file instead. `auth-file.sh` writes that file from the environment, then runs the harness:

1. It reads `FACTORY_HARNESS_AUTH_FILE` (the destination: an absolute path, or one starting with `~/`, which means `$HOME`) and `FACTORY_HARNESS_AUTH_DATA` (the file's whole content, base64 on one line).
2. It writes the file with mode 600, creating missing parent directories with mode 700. An existing file is replaced.
3. It removes both variables from the environment and `exec`s the rest of its arguments.

It exits 2, without starting the harness, when no command follows it, the command is a relative path, a variable is missing or empty, the data is not valid base64, or the destination is relative, a directory, not a regular file, or can't be written. Both refusals of relative paths have the same reason: the harness runs in the agent's worktree. A relative destination would land there, where the exit trap's `wip` commit could push it; a relative command (`./bin/harness`) would run a file from there, which a branch under review can change, with the login in place. Name the harness by a command found in `PATH`, or by an absolute path. Nothing it prints contains the data. `bash factory/harness/auth-file.sh --help` prints its usage.

### Setting it up for CI

1. Log the harness in once on your own machine, then encode its login file on one line:

   ```bash
   base64 -w0 <login file> >auth.b64            # GNU coreutils (Linux, Git Bash)
   base64 <login file> | tr -d '\n' >auth.b64   # macOS
   ```

2. Write the secret's lines into a file outside the repository (`FACTORY_AGENT_ENV` is one secret holding `KEY=VALUE` lines; keep the harness's other settings in it too; a secret holds at most 48 KB, the encoded file included):

   ```
   FACTORY_HARNESS_AUTH_FILE=~/<the harness's config folder>/<login file>
   FACTORY_HARNESS_AUTH_DATA=<the one line from auth.b64>
   ```

3. Store it and delete the local copies: `gh secret set FACTORY_AGENT_ENV <agent.env`, then `rm agent.env auth.b64`.
4. Put the wrapper in front of the harness command in `harness_cmd` (an operator-approved rules change), for example:

   ```yaml
   harness_cmd: bash factory/harness/auth-file.sh <harness> <non-interactive flags>
   ```

   Example, as of the PLAN's harness table (check the harness's own documentation, since CLIs change often): Codex CLI keeps its login in `~/.codex/auth.json`, so `FACTORY_HARNESS_AUTH_FILE=~/.codex/auth.json` and `harness_cmd: bash factory/harness/auth-file.sh codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check`.

5. Preview it without launching anything: dispatch the `build` workflow with `dry_run`, or run `bash scripts/run-agent.sh --role build --dry-run` locally (the same `--role build` the workflow runs). A stopped factory doesn't end a dry run: it says `factory stopped (dry run continues)`, then picks a task as a real run would, and prints the harness argv when there is one to pick; when there is nothing to do, it says why instead. A dry run never runs `harness_install`, so on a runner without the harness it warns `harness binary not found` where a real run would install it first. A local dry run uses `FACTORY_HARNESS_CMD` when that is set, so unset it to see the `harness_cmd` that CI runs.

### Things to know

- **Local runs** don't need the wrapper: your harness is already logged in. `FACTORY_HARNESS_CMD` overrides `harness_cmd` for local and crontab runs, so you can keep the wrapper for CI only. If you do run it locally, it replaces the destination file on every run.
- **Expiring logins.** Some harnesses refresh their login by rewriting the file. On CI that copy is thrown away with the runner, so when the login in the secret expires, repeat the setup.
- **Who can read the file.** It is mode 600 in the runner's home directory: the harness, and any code the harness runs, can read it, as with any harness credential. Removing the two variables keeps them out of the harness's environment and so out of anything that prints it; it is not isolation: a process of the same user can still read the environment the run started with (in Actions the job step holds the whole `FACTORY_AGENT_ENV`, readable through `/proc/<pid>/environ` on Linux). The workflows mask each `FACTORY_AGENT_ENV` value in the job log and remove it from the uploaded agent logs, but that is the base64 text: the decoded file's own tokens are neither masked nor removed, so a harness or agent that prints the file publishes them. Use a login that can do nothing beyond running the harness.
- **`harness_install` and wrappers.** Because the preflight checks the harness command after the wrapper, `harness_install` works behind a wrapper as it does without one: in CI it runs when that command is missing, and a command still missing afterwards (for example installed outside the runner's PATH) stops the run with exit 2 before anything is claimed. Keep the harness command in `harness_cmd`, after the wrapper, rather than hard-coded inside it, or the preflight can't see it.

## Writing another wrapper

- Read what you need from the environment, prepare, `unset` the variables the harness must not see, then `exec "$@"`. Take the harness command as your arguments (`bash factory/harness/<name>.sh <harness> <flags>`), so the preflight finds and installs it.
- Keep it harness-neutral where you can (configure the specific harness through `FACTORY_AGENT_ENV` values or the arguments after the wrapper), and never print a secret, not even under `bash -x`.
- On a setup error, say why on stderr (without the secret) and exit 2, the factory's code for a usage or config error, before the harness starts. run-agent.sh records the run as failed.
- `tests/run.sh` shellchecks every shell file in this folder; add tests in `tests/` for its behaviour, as `tests/test_harness_wrapper.sh` does for `auth-file.sh`.
