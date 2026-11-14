#!/bin/bash
# Syntax-check every GDScript in the project. Usage: ./check_scripts.sh [dir...]
GODOT="${GODOT:-/home/llmdev/.local/bin/godot}"
cd "$(dirname "$0")" || exit 1
DIRS=${*:-scripts tests}
fail=0
for f in $(find $DIRS -name '*.gd' | sort); do
  out=$("$GODOT" --headless --check-only --script "$f" 2>&1)
  if echo "$out" | grep -q 'SCRIPT ERROR'; then
    echo "BAD: $f"
    echo "$out" | grep 'SCRIPT ERROR' | head -4
    fail=1
  fi
done
[ $fail -eq 0 ] && echo "ALL SCRIPTS PARSE OK"
exit $fail
