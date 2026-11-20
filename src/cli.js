'use strict';

const { TodoError } = require('./errors');

const defaultIo = {
  stdout: (line) => process.stdout.write(`${line}\n`),
  stderr: (line) => process.stderr.write(`${line}\n`),
};

// Command handlers: name -> (args, env, io) => void. Later features add entries.
const commands = {};

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
