<!-- factory:spec -->
# todo: a zero-dependency Node.js command-line todo list

## Restated goal
A developer working in a terminal keeps a small todo list in a JSON file next to their work, or in the file named by `TODO_FILE`. With five commands they can add items, list open (or all) items, mark items done and delete them. Everything runs on plain Node.js with no installed packages. It works when every command in the flows prints exactly the documented stdout lines and exits 0, every misuse prints one message to stderr and exits 1, and `node --test` proves both with no dependencies.

## Goals
- G-1: `todo add <text>` stores a new open item and prints its id.
- G-2: `todo list` prints each open item as `<id> <text>`, one per line, in ascending id order.
- G-3: `todo list --all` prints open and done items in ascending id order, with done items marked `[x]`.
- G-4: `todo done <id>` marks an item done; it then drops out of `todo list`.
- G-5: `todo rm <id>` deletes an item; it then appears in no listing.
- G-6: Items persist as JSON in the file named by `TODO_FILE`, or `./todo.json` when it is unset or empty, so separate runs see the same list.
- G-7: Every error (unknown command, missing or bad argument, unknown id, unreadable or corrupt file) prints a message to stderr, prints nothing to stdout, exits 1 and leaves the file unchanged.
- G-8: The tool runs with no npm dependencies, and its tests run with `node --test`.

## Non-goals
- NG-1: No runtime or dev dependencies from npm (no CLI parser, no test framework, no linter).
- NG-2: No editing an item's text, no un-done (reopen), no priorities, due dates, tags or search.
- NG-3: No colour, interactive prompts, or TUI.
- NG-4: No sync, network access, or multiple users; no locking against concurrent writers.
- NG-5: No publishing to the npm registry and no global-install tooling beyond the `bin` field in `package.json`.
- NG-6: No migration of other todo file formats.

## Users
- U-dev: a developer in a terminal (Linux, macOS or Windows) with Node.js >= 18 on PATH, running `node bin/todo.js ...` or `todo ...` via `npm link`, who wants a list that lives in a plain file.

## Flows
- FL-1 (U-dev): `todo add buy milk` -> prints `1` -> `todo list` prints `1 buy milk`.
- FL-2 (U-dev): add two items -> `todo done 1` -> `todo list` prints only `2 <text>` -> `todo list --all` prints `1 [x] <text>` then `2 <text>`.
- FL-3 (U-dev): `todo rm 2` -> `todo list --all` no longer shows id 2; the next `todo add` prints `3`, never `2`.
- FL-4 (U-dev): `TODO_FILE=/tmp/work.json todo add x` -> the item is written to `/tmp/work.json`, and `./todo.json` is untouched.
- FL-5 (U-dev): `todo done 99` (no such id), `todo frob`, `todo add` with no text -> a message on stderr, nothing on stdout, exit 1, file unchanged.
- FL-6 (U-dev): `todo list` with no todo file -> prints nothing, exits 0, and creates no file.

## Design
- D-runtime: CommonJS JavaScript on Node.js >= 18, standard library only (`node:fs`, `node:path`, `node:process`). Why: the idea demands zero dependencies, and `node:test` is stable from 18. Rejected: TypeScript (needs a compiler dependency); ESM (no gain here, and CommonJS keeps `require` in tests simple).
- D-layout: `bin/todo.js` is a thin entry (`#!/usr/bin/env node`) that calls `main(process.argv.slice(2), process.env)` from `src/cli.js` and sets `process.exitCode` from its result. `src/cli.js` parses arguments and dispatches commands; `src/store.js` loads and saves the file; `src/todos.js` holds pure functions over the in-memory list (add, done, rm, list). Why: pure functions are unit-testable, and the CLI layer is testable without spawning. Rejected: one file (features would collide in it).
- D-cli-main: `main(argv, env, io)` returns the exit code (0 or 1) and writes through `io.stdout(line)` / `io.stderr(line)`, defaulting to the process streams. It never calls `process.exit`. Why: in-process tests can capture output and exit codes.
- D-commands: the surface is exactly `add <text...>`, `list`, `list --all`, `done <id>`, `rm <id>`. For `add`, all remaining arguments are joined with single spaces; text that is empty after trimming is an error. `<id>` must be a positive decimal integer (`/^[1-9][0-9]*$/`). Extra arguments to `list`, `done` or `rm`, unknown flags, an unknown command, or no command are errors. Why: a strict, small surface is easy to test. Rejected: `--help` and aliases (not asked for).
- D-output: stdout lines end with `\n`. `add` prints just the new id. `list` prints `<id> <text>` per open item. `list --all` prints `<id> <text>` for open items and `<id> [x] <text>` for done items. Both listings are in ascending id order and print nothing for an empty list. `done` and `rm` print nothing on success. Why: output that scripts can parse; the idea fixed `<id> <text>` and the `[x]` marker.
- D-json-store: the file holds `{"nextId": <int>, "items": [{"id": <int>, "text": <string>, "done": <bool>}]}`, written as 2-space-indented JSON with a trailing newline. Ids start at 1 and come from `nextId`, so a deleted id is never reused. The path is `env.TODO_FILE`, or `todo.json` in the current directory when it is unset or empty, resolved against the current directory. A missing file reads as an empty list (`nextId` 1). Read-only commands never create the file. Writes go to a temp file in the same directory, which is then renamed over the target, so a crash cannot leave half a file. Why: plain, human-readable state that survives deletes. Rejected: a bare array with max+1 ids (reuses ids after `rm` of the last item).
- D-errors: every failure throws a `TodoError` with a message. `main` catches it, writes `todo: <message>` to stderr and returns 1, with nothing on stdout and the file unchanged. Unexpected exceptions are also reported as `todo: <message>` with exit 1, never a stack trace. A file that is not valid JSON, or not of the D-json-store shape, is an error naming the path. Marking an already-done item done again succeeds as a no-op. Why: one predictable error path for users and tests.
- D-tests: tests are `test/**/*.test.js`, using only `node:test` and `node:assert/strict`. Unit tests call `src/todos.js` and `main` directly. End-to-end tests spawn `process.execPath bin/todo.js` with `TODO_FILE` set to a file in a fresh `fs.mkdtempSync(path.join(os.tmpdir(), ...))` directory, so tests never touch the repo's `todo.json`. Why: zero dependencies; tests stay isolated and can run in parallel.
- D-package: `package.json` is `private`, has no dependencies, and sets `"bin": {"todo": "bin/todo.js"}`, `"engines": {"node": ">=18"}` and `"scripts": {"test": "node --test \"test/**/*.test.js\""}`. There is no lockfile. Why: `npm link` and `npm test` work with nothing to install.

## Open questions
- Q-1: How is an open item shown in `list --all`: `<id> <text>`, or `<id> [ ] <text>`?
  - Assumption: `<id> <text>`, as in `list`; only done items carry `[x]`, placed after the id (D-output).
  - Status: assumed
- Q-2: May a deleted id be reused?
  - Assumption: no; ids come from a stored `nextId` counter (D-json-store).
  - Status: assumed
- Q-3: What do `done` on an already-done item, and `done`/`rm` on an unknown id, do?
  - Assumption: re-marking a done item succeeds silently; an unknown id is an error with exit 1 (D-errors).
  - Status: assumed
- Q-4: What happens when the todo file is missing, empty, or corrupt?
  - Assumption: a missing file reads as an empty list and is created only on the first write; an empty or invalid file is an error that names the path, and it is never overwritten (D-json-store, D-errors).
  - Status: assumed
- Q-5: Do `done` and `rm` print anything on success? Is there a `--help`?
  - Assumption: they print nothing. There is no `--help`; no command, or an unknown one, prints a usage message to stderr and exits 1 (D-commands, D-output).
  - Status: assumed
- Q-6: How is multi-word text given to `add`?
  - Assumption: all arguments after `add` are joined with single spaces, so quoting is optional (D-commands).
  - Status: assumed
- Q-7: Which Node.js versions are supported?
  - Assumption: >= 18, the first line with a stable `node:test`; checked here on v24.13.0 only (D-runtime).
  - Status: assumed

## Spikes
- spike-node-test-empty: does a `node --test` glob exit 0 while there are no tests yet, and 1 when a test fails? `bash spike/run.sh` exited 0 on Node v24.13.0, printing "empty-glob exit=0", "pass-glob exit=0", "fail-glob exit=1" and "fail-file exit=1". factory/spike-node-test-empty at 41c5779bc6bba3ff8d6db74921944bf0a02a3846.

## Gate
- `project.setup: none`: nothing to install (NG-1, D-package).
- `gate.test: node --test "test/**/*.test.js"`: runs every test file. It exits 0 with no tests yet and 1 on a failure (spike-node-test-empty). The explicit glob keeps Node's default discovery away from files outside `test/`.
- `gate.test_files: node --test {files}`: runs the given files and exits 1 on a failure (same spike).
- `gate.test_globs: test/**`: every test file lives under `test/` (D-tests).
- `gate.lint: none`, `gate.typecheck: none`: no zero-dependency linter or type checker is in scope (NG-1).
- `merge.protected_paths: package.json`: the manifest holds the test script and the dependency list, which must stay empty.
