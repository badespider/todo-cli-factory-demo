# Flattens the factory.config.yaml subset (docs/CONTRACTS.md) into lines:
#   path.to.key=value        scalars
#   path.to.key[]=value      list items
# On a syntax error prints "ERR<TAB>line<TAB>message" and exits 2.
# POSIX awk only (tested with gawk --posix); run with -v bom="<UTF-8 BOM bytes>".

function bad(msg) {
  printf "ERR\t%d\t%s\n", NR, msg
  failed = 1
  exit 2
}

function path_to(level,    i, p) {
  p = keys[0]
  for (i = 1; i <= level; i++) p = p "." keys[i]
  return p
}

function parse_value(s,    i, c, q, out, prev, first, last, n) {
  sub(/^ +/, "", s)
  q = ""
  out = ""
  prev = " "
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (q == "") {
      if (c == "#" && prev == " ") break
      if (c == "\"" || c == "'") q = c
    } else if (c == q) {
      q = ""
    }
    out = out c
    prev = c
  }
  if (q != "") bad("unterminated quote")
  sub(/ +$/, "", out)
  first = substr(out, 1, 1)
  if (length(out) >= 2) {
    last = substr(out, length(out), 1)
    if ((first == "\"" || first == "'") && first == last) return substr(out, 2, length(out) - 2)
  }
  if (first == "[" || first == "{") bad("flow style ([...] or {...}) is not supported; use block style")
  return out
}

BEGIN { failed = 0 }

{
  line = $0
  sub(/\r$/, "", line)
  if (NR == 1 && bom != "" && index(line, bom) == 1) line = substr(line, length(bom) + 1)
  if (index(line, "\t") > 0) bad("tab character; indent with spaces")

  probe = line
  sub(/^ +/, "", probe)
  if (probe == "" || substr(probe, 1, 1) == "#") next

  match(line, /^ */)
  ind = RLENGTH
  if (ind % 2 != 0) bad("indentation must be a multiple of 2 spaces")
  level = ind / 2
  body = substr(line, ind + 1)

  if (body == "-" || substr(body, 1, 2) == "- ") {
    if (level == 0 || !open[level - 1]) bad("list item without an open 'key:' two spaces above it")
    parent = path_to(level - 1)
    if (kind[parent] == "map") bad("mixing list items and keys under '" parent "'")
    kind[parent] = "list"
    children[parent] = 1
    for (i = level; i <= maxlevel; i++) open[i] = 0
    print parent "[]=" parse_value(substr(body, 2))
    next
  }

  if (match(body, /^[A-Za-z0-9_-]+:/) == 0) bad("expected 'key: value', 'key:' or '- item'")
  key = substr(body, 1, RLENGTH - 1)
  rest = substr(body, RLENGTH + 1)
  if (rest != "" && substr(rest, 1, 1) != " ") bad("missing space after ':'")

  if (level > 0) {
    if (!open[level - 1]) bad("unexpected indentation")
    parent = path_to(level - 1)
    if (kind[parent] == "list") bad("mixing keys and list items under '" parent "'")
    kind[parent] = "map"
    children[parent] = 1
  }

  keys[level] = key
  for (i = level; i <= maxlevel; i++) open[i] = 0
  if (level > maxlevel) maxlevel = level
  path = path_to(level)
  if (path in seen) bad("duplicate key '" path "'")
  seen[path] = 1

  value = parse_value(rest)
  if (value == "") {
    open[level] = 1
    containers[path] = 1
  } else {
    print path "=" value
  }
}

END {
  if (failed) exit 2
  for (p in containers) if (!(p in children)) print p "="
}
