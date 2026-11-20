'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const BIN = path.join(__dirname, '..', 'bin', 'todo.js');

function runBin(args, file, cwd) {
  const env = { ...process.env, TODO_FILE: file };
  return spawnSync(process.execPath, [BIN, ...args], { cwd, env, encoding: 'utf8' });
}

function assertRejected(label, r) {
  assert.equal(r.status, 1, `${label}: flag was not rejected, exit ${r.status}, not 1`);
  assert.equal(r.stdout, '', `${label}: stdout is not empty: ${JSON.stringify(r.stdout)}`);
  const first = r.stderr.split('\n')[0];
  assert.ok(first.startsWith('todo: '), `${label}: stderr does not start with "todo: ": ${JSON.stringify(r.stderr)}`);
}

test('issue-11: add rejects flag arguments and does not create a missing file', () => {
  for (const args of [['add', '--all'], ['add', '-x'], ['add', 'buy', '--now']]) {
    const label = JSON.stringify(args);
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-i11-'));
    const file = path.join(dir, 'todo.json');
    const r = runBin(args, file, dir);
    assertRejected(label, r);
    assert.equal(fs.existsSync(file), false, `${label}: the todo file was created`);
  }
});

test('issue-11: add with a flag leaves an existing file byte-for-byte unchanged', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-i11-'));
  const file = path.join(dir, 'todo.json');
  const before = '{\n  "nextId": 2,\n  "items": [\n    {\n      "id": 1,\n      "text": "eggs",\n      "done": false\n    }\n  ]\n}\n';
  fs.writeFileSync(file, before);
  const r = runBin(['add', '--all'], file, dir);
  assertRejected('["add","--all"] on existing file', r);
  assert.equal(fs.readFileSync(file, 'utf8'), before, 'the todo file changed');
});

test('issue-11: add keeps a bare "-" as item text, since it is an operand, not a flag', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-i11-'));
  const file = path.join(dir, 'todo.json');
  const r = runBin(['add', 'pay', 'rent', '-', 'today'], file, dir);
  assert.equal(r.status, 0, `bare "-" was rejected, exit ${r.status}: ${JSON.stringify(r.stderr)}`);
  assert.equal(r.stdout, '1\n');
  const list = runBin(['list'], file, dir);
  assert.equal(list.stdout, '1 pay rent - today\n');
});
