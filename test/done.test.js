'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.join(__dirname, '..');
const BIN = path.join(ROOT, 'bin', 'todo.js');

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'todo-f5-'));
}

function runBin(args, file, cwd) {
  assert.ok(fs.existsSync(BIN), 'bin/todo.js missing');
  const env = { ...process.env, TODO_FILE: file };
  return spawnSync(process.execPath, [BIN, ...args], { cwd, env, encoding: 'utf8' });
}

function stderrLines(r) {
  return r.stderr.split('\n').filter((l) => l !== '');
}

// Two open items: `a` (id 1) and `b` (id 2).
function setupTwo() {
  const dir = tmpDir();
  const file = path.join(dir, 'todo.json');
  assert.equal(runBin(['add', 'a'], file, dir).status, 0, 'add a failed');
  assert.equal(runBin(['add', 'b'], file, dir).status, 0, 'add b failed');
  return { dir, file };
}

function assertSilentOk(r, label) {
  assert.equal(r.status, 0, `${label}: exit ${r.status}, not 0`);
  assert.equal(r.stdout, '', `${label}: stdout is ${JSON.stringify(r.stdout)}, not empty`);
}

function assertTodoError(r, label) {
  assert.equal(r.status, 1, `${label}: exit ${r.status}, not 1`);
  assert.equal(r.stdout, '', `${label}: stdout is ${JSON.stringify(r.stdout)}, not empty`);
  const lines = stderrLines(r);
  assert.ok(lines.length >= 1 && lines[0].startsWith('todo: '), `${label}: stderr has no line starting with "todo: "`);
}

test('F5-ac1: done 1 exits 0 silently and list then prints only the open item', () => {
  const { dir, file } = setupTwo();
  assertSilentOk(runBin(['done', '1'], file, dir), 'done 1');
  const r = runBin(['list'], file, dir);
  assert.equal(r.status, 0, `list exited ${r.status}, not 0`);
  assert.equal(r.stdout, '2 b\n', `list stdout is ${JSON.stringify(r.stdout)}`);
});

test('F5-ac2: list --all prints done items with [x] and open items plainly, by id', () => {
  const { dir, file } = setupTwo();
  assertSilentOk(runBin(['done', '1'], file, dir), 'done 1');
  const r = runBin(['list', '--all'], file, dir);
  assert.equal(r.status, 0, `list --all exited ${r.status}, not 0`);
  assert.equal(r.stdout, '1 [x] a\n2 b\n', `list --all stdout is ${JSON.stringify(r.stdout)}`);
});

test('F5-ac3: done on an already-done item is a silent no-op', () => {
  const { dir, file } = setupTwo();
  assertSilentOk(runBin(['done', '1'], file, dir), 'first done 1');
  assertSilentOk(runBin(['done', '1'], file, dir), 'second done 1');
  const r = runBin(['list', '--all'], file, dir);
  assert.equal(r.status, 0, `list --all exited ${r.status}, not 0`);
  assert.equal(r.stdout.split('\n')[0], '1 [x] a', `list --all stdout is ${JSON.stringify(r.stdout)}`);
});

test('F5-ac4: done on an unknown id exits 1 with a todo: error and leaves the file unchanged', () => {
  const { dir, file } = setupTwo();
  const before = fs.readFileSync(file);
  assertTodoError(runBin(['done', '99'], file, dir), 'done 99');
  assert.ok(before.equals(fs.readFileSync(file)), 'the todo file changed');
});

test('F5-ac5: done with a bad, missing or extra id exits 1 with a todo: error', () => {
  for (const args of [['done', 'abc'], ['done', '0'], ['done'], ['done', '1', '2']]) {
    const { dir, file } = setupTwo();
    assertTodoError(runBin(args, file, dir), JSON.stringify(args));
  }
});
