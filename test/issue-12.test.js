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
