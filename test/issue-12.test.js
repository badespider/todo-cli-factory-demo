'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const BIN = path.join(__dirname, '..', 'bin', 'todo.js');

const CASES = {
  'stale-nextid': '{"nextId": 1, "items": [{"id": 1, "text": "a", "done": false}]}',
  'nextid-equal-to-max': '{"nextId": 3, "items": [{"id": 1, "text": "a", "done": false}, {"id": 3, "text": "c", "done": false}]}',
  'duplicate-ids': '{"nextId": 3, "items": [{"id": 1, "text": "a", "done": false}, {"id": 1, "text": "b", "done": false}]}',
};

for (const [name, json] of Object.entries(CASES)) {
  test(`issue-12: add refuses an inconsistent todo file (${name})`, () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-i12-'));
    const file = path.join(dir, `${name}.json`);
    const before = json + '\n';
    fs.writeFileSync(file, before);
    const r = spawnSync(process.execPath, [BIN, 'add', 'b'], {
      cwd: dir,
      env: { ...process.env, TODO_FILE: file },
      encoding: 'utf8',
    });
    assert.equal(r.status, 1, `${name}: inconsistent file accepted, add exit ${r.status}, not 1`);
    assert.equal(r.stdout, '', `${name}: stdout is not empty: ${JSON.stringify(r.stdout)}`);
    const first = r.stderr.split('\n')[0];
    assert.ok(first.startsWith('todo: ') && first.includes(file), `${name}: stderr does not name the file: ${JSON.stringify(r.stderr)}`);
    assert.equal(fs.readFileSync(file, 'utf8'), before, `${name}: the todo file was changed`);
  });
}

test('issue-12: a consistent file with gaps in ids is still accepted', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-i12-'));
  const file = path.join(dir, 'todo.json');
  fs.writeFileSync(file, '{"nextId": 5, "items": [{"id": 1, "text": "a", "done": false}, {"id": 3, "text": "c", "done": true}]}\n');
  const r = spawnSync(process.execPath, [BIN, 'add', 'b'], {
    cwd: dir,
    env: { ...process.env, TODO_FILE: file },
    encoding: 'utf8',
  });
  assert.equal(r.status, 0, `consistent file rejected: exit ${r.status}, stderr ${JSON.stringify(r.stderr)}`);
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')).items.map((i) => i.id), [1, 3, 5]);
});

// Ids must stay exact JavaScript integers: past Number.MAX_SAFE_INTEGER, nextId + 1 === nextId,
// so add would write an item whose id is not below nextId (verify finding V1 on PR #14).
const UNSAFE = {
  'nextid-above-max-safe': '{"nextId": 9007199254740992, "items": []}',
  'id-above-max-safe': '{"nextId": 9007199254740994, "items": [{"id": 9007199254740993, "text": "a", "done": false}]}',
  'nextid-at-max-safe': '{"nextId": 9007199254740991, "items": []}',
};

for (const [name, json] of Object.entries(UNSAFE)) {
  test(`issue-12: add refuses a file whose ids would not stay exact (${name})`, () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-i12-'));
    const file = path.join(dir, `${name}.json`);
    const before = json + '\n';
    fs.writeFileSync(file, before);
    const r = spawnSync(process.execPath, [BIN, 'add', 'b'], {
      cwd: dir,
      env: { ...process.env, TODO_FILE: file },
      encoding: 'utf8',
    });
    assert.equal(r.status, 1, `${name}: add exit ${r.status}, not 1; file now ${fs.readFileSync(file, 'utf8')}`);
    assert.equal(r.stdout, '', `${name}: stdout is not empty: ${JSON.stringify(r.stdout)}`);
    const first = r.stderr.split('\n')[0];
    assert.ok(first.startsWith('todo: ') && first.includes(file), `${name}: stderr does not name the file: ${JSON.stringify(r.stderr)}`);
    assert.equal(fs.readFileSync(file, 'utf8'), before, `${name}: the todo file was changed`);
  });
}

test('issue-12: list still reads a file whose nextId is Number.MAX_SAFE_INTEGER', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-i12-'));
  const file = path.join(dir, 'todo.json');
  fs.writeFileSync(file, '{"nextId": 9007199254740991, "items": [{"id": 9007199254740990, "text": "a", "done": false}]}\n');
  const r = spawnSync(process.execPath, [BIN, 'list'], {
    cwd: dir,
    env: { ...process.env, TODO_FILE: file },
    encoding: 'utf8',
  });
  assert.equal(r.status, 0, `list exit ${r.status}, stderr ${JSON.stringify(r.stderr)}`);
  assert.equal(r.stdout, '9007199254740990 a\n');
});
