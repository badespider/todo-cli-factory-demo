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
  return fs.mkdtempSync(path.join(os.tmpdir(), 'todo-f6-'));
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

test('F6-ac1: rm 2 exits 0 silently and list --all then prints only item 1', () => {
  const { dir, file } = setupTwo();
  assertSilentOk(runBin(['rm', '2'], file, dir), 'rm 2');
  const r = runBin(['list', '--all'], file, dir);
  assert.equal(r.status, 0, `list --all exited ${r.status}, not 0`);
  assert.equal(r.stdout, '1 a\n', `list --all stdout is ${JSON.stringify(r.stdout)}`);
});

test('F6-ac2: after rm 2, add c gets id 3 (ids are never reused)', () => {
  const { dir, file } = setupTwo();
  assertSilentOk(runBin(['rm', '2'], file, dir), 'rm 2');
  const r = runBin(['add', 'c'], file, dir);
  assert.equal(r.status, 0, `add c exited ${r.status}, not 0`);
  assert.equal(r.stdout, '3\n', `add c stdout is ${JSON.stringify(r.stdout)}`);
});

test('F6-ac3: rm on an unknown id exits 1 with a todo: error and leaves the file unchanged', () => {
  const { dir, file } = setupTwo();
  const before = fs.readFileSync(file);
  assertTodoError(runBin(['rm', '99'], file, dir), 'rm 99');
  assert.ok(before.equals(fs.readFileSync(file)), 'the todo file changed');
});

test('F6-ac4: rm with a bad, missing or extra id exits 1 with a todo: error', () => {
  for (const args of [['rm', 'abc'], ['rm'], ['rm', '1', '2']]) {
    const { dir, file } = setupTwo();
    assertTodoError(runBin(args, file, dir), JSON.stringify(args));
  }
});
