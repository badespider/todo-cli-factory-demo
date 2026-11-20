'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { TodoError } = require('./errors');

// The todo file: env.TODO_FILE, or todo.json in the current directory when unset or empty.
function resolvePath(env) {
  const file = env && typeof env.TODO_FILE === 'string' && env.TODO_FILE !== '' ? env.TODO_FILE : 'todo.json';
  return path.resolve(file);
}

function isPositiveInt(n) {
  return Number.isInteger(n) && n >= 1;
}

function isValidState(state) {
  if (state === null || typeof state !== 'object' || Array.isArray(state)) return false;
  if (!isPositiveInt(state.nextId) || !Array.isArray(state.items)) return false;
  // Ids come from nextId and are never reused: each id is unique and below nextId.
  const seen = new Set();
  return state.items.every((item) => {
    const ok =
      item !== null &&
      typeof item === 'object' &&
      !Array.isArray(item) &&
      isPositiveInt(item.id) &&
      item.id < state.nextId &&
      !seen.has(item.id) &&
      typeof item.text === 'string' &&
      typeof item.done === 'boolean';
    if (ok) seen.add(item.id);
    return ok;
  });
}

// Returns {nextId, items}. A missing file is an empty list and is not created.
function load(env) {
  const file = resolvePath(env);
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (err) {
    if (err && err.code === 'ENOENT') return { nextId: 1, items: [] };
    throw new TodoError(`cannot read ${file}: ${err && err.message}`);
  }
  let state;
  try {
    state = JSON.parse(text);
  } catch (err) {
    throw new TodoError(`${file} is not valid JSON`);
  }
  if (!isValidState(state)) {
    throw new TodoError(`${file} is not a todo file (expected {"nextId": <int>, "items": [...]})`);
  }
  return state;
}

// Writes the state as 2-space JSON plus a newline: temp file in the same directory, then rename.
function save(env, state) {
  const file = resolvePath(env);
  const tmp = path.join(path.dirname(file), `.${path.basename(file)}.${process.pid}.${Date.now()}.tmp`);
  try {
    fs.writeFileSync(tmp, JSON.stringify(state, null, 2) + '\n');
    fs.renameSync(tmp, file);
  } catch (err) {
    try {
      fs.unlinkSync(tmp);
    } catch (ignored) {
      // the temp file was never created or is already gone
    }
    throw new TodoError(`cannot write ${file}: ${err && err.message}`);
  }
}

module.exports = { resolvePath, load, save };
