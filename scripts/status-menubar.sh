#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

found=0

print_matches() {
  local title="$1"
  local pattern="$2"
  local output
  output="$(pgrep -fl "$pattern" || true)"
  if [ -n "$output" ]; then
    found=1
    echo "$title"
    echo "$output" | sed 's/^/  /'
  fi
}

print_matches "JoyHarness service runtime:" 'python.* -m src( |$)|Python\.app/.*/Python -m src( |$)'
print_matches "JoyHarness app runtime:" 'JoyHarness\.app/Contents/MacOS/JoyHarness'

if [ "$found" -eq 0 ]; then
  echo "No JoyHarness runtime or menu bar app is running."
fi
