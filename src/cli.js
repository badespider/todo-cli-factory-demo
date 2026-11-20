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

// list: open items as `<id> <text>`, ascending by id. Read-only: never creates the file.
commands.list = (args, env, io) => {
  if (args.length > 0) {
    const arg = args[0];
    throw new TodoError(arg.startsWith('-') ? `unknown flag for list: ${arg}` : `unexpected argument for list: ${arg}`);
  }
  for (const item of todos.openItems(store.load(env))) {
    io.stdout(`${item.id} ${item.text}`);
  }
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
