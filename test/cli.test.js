'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.join(__dirname, '..');
const BIN = path.join(ROOT, 'bin', 'todo.js');
const CLI = path.join(ROOT, 'src', 'cli.js');

function runBin(args) {
  assert.ok(fs.existsSync(BIN), 'bin/todo.js missing');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-f1-'));
  const env = { ...process.env, TODO_FILE: path.join(dir, 'todo.json') };
  const r = spawnSync(process.execPath, [BIN, ...args], { cwd: dir, env, encoding: 'utf8' });
  return r;
}

function assertOneTodoErrorLine(stderr) {
  const lines = stderr.split('\n').filter((l) => l !== '');
  assert.equal(lines.length, 1, `expected one stderr line, got ${lines.length}`);
  assert.ok(lines[0].startsWith('todo: '), `stderr line does not start with "todo: ": ${lines[0]}`);
}

test('F1-ac1: no arguments exits 1 with one todo: line on stderr', () => {
  const r = runBin([]);
  assert.equal(r.status, 1, 'exit code is not 1');
  assert.equal(r.stdout, '', 'stdout is not empty');
  assertOneTodoErrorLine(r.stderr);
});

test('F1-ac2: unknown command exits 1 with one todo: line on stderr', () => {
  const r = runBin(['frob']);
  assert.equal(r.status, 1, 'exit code is not 1');
  assert.equal(r.stdout, '', 'stdout is not empty');
  assertOneTodoErrorLine(r.stderr);
});

test('F1-ac3: main(["frob"]) returns 1, writes one todo: stderr line, never calls process.exit', () => {
  let mod;
  try {
    mod = require(CLI);
  } catch (e) {
    assert.fail('src/cli.js could not be loaded');
  }
  assert.equal(typeof mod.main, 'function', 'src/cli.js does not export main');
  const out = [];
  const err = [];
  const io = { stdout: (line) => out.push(line), stderr: (line) => err.push(line) };
  const realExit = process.exit;
  let exitCalled = false;
  process.exit = () => { exitCalled = true; };
  let code;
  try {
    code = mod.main(['frob'], {}, io);
  } finally {
    process.exit = realExit;
  }
  assert.equal(exitCalled, false, 'main called process.exit');
  assert.equal(code, 1, 'main did not return 1');
  assert.deepEqual(out, [], 'main wrote to stdout');
  assert.equal(err.length, 1, `expected one stderr line, got ${err.length}`);
  assert.ok(String(err[0]).startsWith('todo: '), `stderr line does not start with "todo: ": ${err[0]}`);
});
