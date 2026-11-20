'use strict';

const { TodoError } = require('./errors');
const store = require('./store');
const todos = require('./todos');

const defaultIo = {
  stdout: (line) => process.stdout.write(`${line}\n`),
  stderr: (line) => process.stderr.write(`${line}\n`),
};

// Command handlers: name -> (args, env, io) => void. Later features add entries.
const commands = {};

// add <text...>: arguments joined with single spaces; blank text is an error and touches no file.
commands.add = (args, env, io) => {
  const text = args.join(' ');
  if (text.trim() === '') {
    throw new TodoError('missing item text');
  }
  const state = store.load(env);
  store.save(env, todos.addItem(state, text));
  io.stdout(String(state.nextId));
};

// list [--all]: open items as `<id> <text>`; with --all, done items too as `<id> [x] <text>`.
// Ascending by id. Read-only: never creates the file.
commands.list = (args, env, io) => {
  let all = false;
  if (args.length > 0 && args[0] === '--all') {
    all = true;
    args = args.slice(1);
  }
  if (args.length > 0) {
    const arg = args[0];
    throw new TodoError(arg.startsWith('-') ? `unknown flag for list: ${arg}` : `unexpected argument for list: ${arg}`);
  }
  const state = store.load(env);
  for (const item of all ? todos.allItems(state) : todos.openItems(state)) {
    io.stdout(item.done ? `${item.id} [x] ${item.text}` : `${item.id} ${item.text}`);
  }
};

// Parses exactly one `<id>` argument (/^[1-9][0-9]*$/) for the named command.
function parseId(name, args) {
  if (args.length === 0) throw new TodoError(`missing id for ${name}`);
  if (args.length > 1) throw new TodoError(`unexpected argument for ${name}: ${args[1]}`);
  if (!/^[1-9][0-9]*$/.test(args[0])) throw new TodoError(`invalid id: ${args[0]}`);
  return Number(args[0]);
}

// done <id>: marks the item done; silent on success, a no-op when already done.
commands.done = (args, env, io) => {
  const id = parseId('done', args);
  const state = store.load(env);
  const next = todos.markDone(state, id);
  if (next === null) throw new TodoError(`no item with id ${id}`);
  if (state.items.some((item) => item.id === id && !item.done)) store.save(env, next);
};

// rm <id>: deletes the item; silent on success. Unknown id is an error and touches no file.
commands.rm = (args, env) => {
  const id = parseId('rm', args);
  const state = store.load(env);
  const next = todos.removeItem(state, id);
  if (next === null) throw new TodoError(`no item with id ${id}`);
  store.save(env, next);
};

function run(argv, env, io) {
  if (argv.length === 0) {
    throw new TodoError('missing command');
  }
  const [name, ...args] = argv;
  if (!Object.prototype.hasOwnProperty.call(commands, name)) {
    throw new TodoError(`unknown command: ${name}`);
  }
  commands[name](args, env, io);
}

// Returns the exit code (0 or 1). Never calls process.exit.
function main(argv, env = process.env, io = defaultIo) {
  try {
    run(argv, env || {}, io);
    return 0;
  } catch (err) {
    const message = err && err.message ? String(err.message).split('\n')[0] : String(err);
    io.stderr(`todo: ${message}`);
    return 1;
  }
}

module.exports = { main, commands };
