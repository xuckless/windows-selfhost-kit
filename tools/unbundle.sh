#!/usr/bin/env bash
# Recreate the windows-selfhost-kit folder from the single-file edition (windows-selfhost-kit.md).
#
#   bash unbundle.sh windows-selfhost-kit.md [output-parent-dir]
#
# Writes <output-parent-dir>/windows-selfhost-kit/... (default: current folder) and verifies
# every file against the checksums at the end of the .md file.
set -euo pipefail
md="${1:?Usage: unbundle.sh windows-selfhost-kit.md [output-parent-dir]}"
parent="${2:-.}"
[ -f "$md" ] || { echo "No such file: $md" >&2; exit 1; }
mkdir -p "$parent/windows-selfhost-kit"
out="$(cd "$parent/windows-selfhost-kit" && pwd)"

tr -d '\r' < "$md" | awk -v out="$out" '
  function fail(msg) { print "unbundle: " msg > "/dev/stderr"; bad = 1; exit 1 }
  function write_file(path, n,    i, dir) {
    if (path ~ /(^|\/)\.\.(\/|$)/ || path ~ /^\//) fail("unsafe path: " path)
    dir = path; sub(/\/[^\/]*$/, "", dir)
    if (dir != path) system("mkdir -p \"" out "/" dir "\"")
    printf "" > (out "/" path)
    for (i = 1; i <= n; i++) print buf[i] > (out "/" path)
    close(out "/" path)
    count++
  }
  state == "readme" && $0 == "<!-- END README -->" { write_file("README.md", n); state = ""; next }
  state == "readme" { buf[++n] = $0; next }
  state == "" && $0 == "<!-- BEGIN README -->" { state = "readme"; n = 0; next }
  state == "" && /^### File: `windows-selfhost-kit\/.*`$/ {
    path = $0; sub(/^### File: `windows-selfhost-kit\//, "", path); sub(/`$/, "", path)
    state = "want_fence"; next
  }
  state == "want_fence" && /^```/ { fence = $0; sub(/[^`].*$/, "", fence); state = "body"; n = 0; next }
  state == "body" && $0 == fence { write_file(path, n); state = ""; next }
  state == "body" { buf[++n] = $0; next }
  END { if (!bad) print "unbundle: wrote " count " files to " out }
'

# Verify checksums and make scripts executable.
sums="$(tr -d '\r' < "$md" | awk '/^## Checksums/{f=1; next} f && /^```/{ if (in_) exit; in_=1; next } f && in_')"
(cd "$out" && printf '%s\n' "$sums" | sha256sum -c --quiet -) && echo "unbundle: all checksums OK"
find "$out" -name '*.sh' -exec chmod +x {} +
