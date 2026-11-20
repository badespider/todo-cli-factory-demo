'use strict';

// Every expected failure is a TodoError; main() reports it as `todo: <message>`.
class TodoError extends Error {
  constructor(message) {
    super(message);
    this.name = 'TodoError';
  }
}

module.exports = { TodoError };
