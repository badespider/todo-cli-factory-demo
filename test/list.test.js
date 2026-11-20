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
  return fs.mkdtempSync(path.join(os.tmpdir(), 'todo-f4-'));
}

function runBin(args, file, cwd) {
  assert.ok(fs.existsSync(BIN), 'bin/todo.js missing');
  const env = { ...process.env, TODO_FILE: file };
  return spawnSync(process.execPath, [BIN, ...args], { cwd, env, encoding: 'utf8' });
}

function stderrLines(r) {
  return r.stderr.split('\n').filter((l) => l !== '');
}

test('F4-ac1: list after two adds prints both open items in ascending id order', () => {
  const dir = tmpDir();
  const file = path.join(dir, 'todo.json');
  assert.equal(runBin(['add', 'buy', 'milk'], file, dir).status, 0, 'first add failed');
  assert.equal(runBin(['add', 'eggs'], file, dir).status, 0, 'second add failed');
  const r = runBin(['list'], file, dir);
  assert.equal(r.status, 0, `list exited ${r.status}, not 0`);
  assert.equal(r.stdout, '1 buy milk\n2 eggs\n', `list stdout is ${JSON.stringify(r.stdout)}`);
});

test('F4-ac2: list on a missing file prints nothing, exits 0 and does not create the file', () => {
  const dir = tmpDir();
  const file = path.join(dir, 'todo.json');
  const r = runBin(['list'], file, dir);
  assert.equal(r.status, 0, `list exited ${r.status}, not 0`);
  assert.equal(r.stdout, '', `list stdout is ${JSON.stringify(r.stdout)}, not empty`);
  assert.equal(fs.existsSync(file), false, 'list created the todo file');
});

test('F4-ac3: list with an extra argument or an unknown flag exits 1 with a todo: error', () => {
  for (const args of [['list', 'extra'], ['list', '--bogus']]) {
    const label = JSON.stringify(args);
    const dir = tmpDir();
    const file = path.join(dir, 'todo.json');
    const r = runBin(args, file, dir);
    assert.equal(r.status, 1, `${label}: exit ${r.status}, not 1`);
    assert.equal(r.stdout, '', `${label}: stdout is ${JSON.stringify(r.stdout)}, not empty`);
    const lines = stderrLines(r);
    assert.ok(lines.length >= 1 && lines[0].startsWith('todo: '), `${label}: stderr has no line starting with "todo: "`);
  }
});

test('F4-ac4: list on a file that is not JSON exits 1, names the path and leaves the file unchanged', () => {
  const dir = tmpDir();
  const file = path.join(dir, 'todo.json');
  fs.writeFileSync(file, 'not json');
  const r = runBin(['list'], file, dir);
  assert.equal(r.status, 1, `list exited ${r.status}, not 1`);
  assert.equal(r.stdout, '', `list stdout is ${JSON.stringify(r.stdout)}, not empty`);
  const lines = stderrLines(r);
  assert.ok(
    lines.some((l) => l.startsWith('todo: ') && l.includes(file)),
    'stderr has no "todo: " line containing the file path',
  );
  assert.equal(fs.readFileSync(file, 'utf8'), 'not json', 'the file was changed');
});
