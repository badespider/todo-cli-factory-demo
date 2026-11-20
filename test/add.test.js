'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.join(__dirname, '..');
const BIN = path.join(ROOT, 'bin', 'todo.js');
const TODOS = path.join(ROOT, 'src', 'todos.js');

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'todo-f3-'));
}

function runBin(args, file, cwd) {
  assert.ok(fs.existsSync(BIN), 'bin/todo.js missing');
  const env = { ...process.env, TODO_FILE: file };
  return spawnSync(process.execPath, [BIN, ...args], { cwd, env, encoding: 'utf8' });
}

function readJson(file) {
  assert.ok(fs.existsSync(file), `${file} was not written`);
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

test('F3-ac1: add buy milk on a missing file prints 1 and stores one open item', () => {
  const dir = tmpDir();
  const file = path.join(dir, 'todo.json');
  const r = runBin(['add', 'buy', 'milk'], file, dir);
  assert.equal(r.status, 0, `add exited ${r.status}, not 0`);
  assert.equal(r.stdout, '1\n', `stdout is not "1\\n": ${JSON.stringify(r.stdout)}`);
  assert.deepEqual(readJson(file), {
    nextId: 2,
    items: [{ id: 1, text: 'buy milk', done: false }],
  });
});

test('F3-ac2: a second add prints 2', () => {
  const dir = tmpDir();
  const file = path.join(dir, 'todo.json');
  const first = runBin(['add', 'buy', 'milk'], file, dir);
  assert.equal(first.status, 0, `first add exited ${first.status}, not 0`);
  const r = runBin(['add', 'eggs'], file, dir);
  assert.equal(r.status, 0, `second add exited ${r.status}, not 0`);
  assert.equal(r.stdout, '2\n', `stdout is not "2\\n": ${JSON.stringify(r.stdout)}`);
});

test('F3-ac3: add with no text or blank text exits 1, prints a todo: error and leaves the file unchanged', () => {
  for (const args of [['add'], ['add', '   ']]) {
    const label = JSON.stringify(args);
    // absent file stays absent
    const dir = tmpDir();
    const file = path.join(dir, 'todo.json');
    const r = runBin(args, file, dir);
    assert.equal(r.status, 1, `${label}: exit ${r.status}, not 1`);
    assert.equal(r.stdout, '', `${label}: stdout is not empty`);
    const lines = r.stderr.split('\n').filter((l) => l !== '');
    assert.ok(lines.length >= 1 && lines[0].startsWith('todo: '), `${label}: stderr has no line starting with "todo: "`);
    assert.equal(fs.existsSync(file), false, `${label}: the absent file was created`);

    // an existing file is not changed
    const dir2 = tmpDir();
    const file2 = path.join(dir2, 'todo.json');
    const before = JSON.stringify({ nextId: 2, items: [{ id: 1, text: 'a', done: false }] }, null, 2) + '\n';
    fs.writeFileSync(file2, before);
    const r2 = runBin(args, file2, dir2);
    assert.equal(r2.status, 1, `${label} (existing file): exit ${r2.status}, not 1`);
    assert.equal(r2.stdout, '', `${label} (existing file): stdout is not empty`);
    assert.equal(fs.readFileSync(file2, 'utf8'), before, `${label}: the existing file changed`);
  }
});

test('F3-ac4: addItem(state, text) appends an open item with the old nextId and bumps nextId', () => {
  let mod;
  try {
    mod = require(TODOS);
  } catch (e) {
    assert.fail('src/todos.js could not be loaded');
  }
  assert.equal(typeof mod.addItem, 'function', 'src/todos.js does not export addItem');
  const state = { nextId: 5, items: [{ id: 3, text: 'old', done: true }] };
  const snapshot = JSON.parse(JSON.stringify(state));
  const next = mod.addItem(state, 'new thing');
  assert.equal(next.nextId, 6, 'nextId was not increased by one');
  assert.deepEqual(next.items, [
    { id: 3, text: 'old', done: true },
    { id: 5, text: 'new thing', done: false },
  ]);
  assert.deepEqual(state, snapshot, 'addItem changed its input state');
});

test('F3-ac5: TODO_FILE decides where the item goes, not the working directory', () => {
  const a = tmpDir();
  const b = tmpDir();
  const file = path.join(a, 'work.json');
  const r = runBin(['add', 'x'], file, b);
  assert.equal(r.status, 0, `add exited ${r.status}, not 0`);
  const state = readJson(file);
  assert.deepEqual(state.items, [{ id: 1, text: 'x', done: false }]);
  assert.equal(fs.existsSync(path.join(b, 'todo.json')), false, 'a todo.json was created in the working directory');
});
