#!/usr/bin/env bash
# Question: which `node --test` invocation exits 0 with no tests yet, and non-zero on a failing test?
set -u
d=$(mktemp -d); cd "$d"
node --version
node --test 'test/**/*.test.js' </dev/null >/dev/null 2>&1; echo "empty-glob exit=$?"
node --test </dev/null >/dev/null 2>&1; echo "bare-empty exit=$?"
mkdir test
echo "require('node:test')('ok',()=>{});" > test/a.test.js
node --test 'test/**/*.test.js' </dev/null >/dev/null 2>&1; echo "pass-glob exit=$?"
echo "require('node:test')('bad',()=>{throw new Error('x')});" > test/b.test.js
node --test 'test/**/*.test.js' </dev/null >/dev/null 2>&1; echo "fail-glob exit=$?"
node --test test/b.test.js </dev/null >/dev/null 2>&1; echo "fail-file exit=$?"
