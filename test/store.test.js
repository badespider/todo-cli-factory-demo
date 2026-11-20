'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const STORE = path.join(ROOT, 'src', 'store.js');
const ERRORS = path.join(ROOT, 'src', 'errors.js');

function loadStore(names) {
  assert.ok(fs.existsSync(STORE), 'src/store.js missing');
  let mod;
  try {
    mod = require(STORE);
  } catch (e) {
    assert.fail('src/store.js could not be loaded');
  }
  for (const name of names) {
    assert.equal(typeof mod[name], 'function', `src/store.js does not export ${name}`);
  }
  return mod;
}

function freshDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'todo-f2-'));
}

function assertTodoErrorNamingPath(fn, file) {
  const { TodoError } = require(ERRORS);
  let thrown;
  try {
    fn();
  } catch (e) {
    thrown = e;
  }
  assert.ok(thrown !== undefined, 'load did not throw');
  assert.ok(thrown instanceof TodoError, `load threw ${thrown && thrown.name}, not a TodoError`);
  assert.ok(String(thrown.message).includes(file), `error message does not name the file: ${thrown.message}`);
}

test('F2-ac1: load on a missing file returns an empty list and creates no file', () => {
  const { load } = loadStore(['load']);
  const dir = freshDir();
  const file = path.join(dir, 'todo.json');
  const state = load({ TODO_FILE: file });
  assert.deepEqual(state, { nextId: 1, items: [] });
  assert.equal(fs.existsSync(file), false, 'load created the file');
  assert.deepEqual(fs.readdirSync(dir), [], 'load left files in the directory');
});

test('F2-ac2: save then load round-trips and writes 2-space JSON with a trailing newline', () => {
  const { load, save } = loadStore(['load', 'save']);
  const dir = freshDir();
  const file = path.join(dir, 'todo.json');
  const env = { TODO_FILE: file };
  const state = {
    nextId: 4,
    items: [
      { id: 1, text: 'buy milk', done: false },
      { id: 3, text: 'call mum', done: true },
    ],
  };
  save(env, state);
  assert.equal(fs.readFileSync(file, 'utf8'), JSON.stringify(state, null, 2) + '\n');
  assert.deepEqual(load(env), state);
  assert.deepEqual(fs.readdirSync(dir), ['todo.json'], 'save left temp files behind');
});

test('F2-ac3: resolvePath defaults to ./todo.json and resolves TODO_FILE against the cwd', () => {
  const { resolvePath } = loadStore(['resolvePath']);
  assert.equal(resolvePath({}), path.resolve('todo.json'));
  assert.equal(resolvePath({ TODO_FILE: '' }), path.resolve('todo.json'));
  assert.equal(resolvePath({ TODO_FILE: 'x/w.json' }), path.resolve('x/w.json'));
});

test('F2-ac4: load on invalid JSON throws a TodoError naming the path and leaves the file unchanged', () => {
  const { load } = loadStore(['load']);
  const file = path.join(freshDir(), 'todo.json');
  fs.writeFileSync(file, 'not json');
  assertTodoErrorNamingPath(() => load({ TODO_FILE: file }), file);
  assert.equal(fs.readFileSync(file, 'utf8'), 'not json', 'file content changed');
});

test('F2-ac5: load on valid JSON of the wrong shape throws a TodoError naming the path', () => {
  const { load } = loadStore(['load']);
  const file = path.join(freshDir(), 'todo.json');
  fs.writeFileSync(file, '[]');
  assertTodoErrorNamingPath(() => load({ TODO_FILE: file }), file);
});
