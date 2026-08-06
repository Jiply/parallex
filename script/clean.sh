#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$ROOT_DIR" == "/" || ! -f "$ROOT_DIR/README.md" || ! -d "$ROOT_DIR/Sources" ]]; then
  echo "Refusing to clean an unrecognized project root: $ROOT_DIR" >&2
  exit 1
fi

rm -rf -- "$ROOT_DIR/.build" "$ROOT_DIR/dist"
find "$ROOT_DIR" -path "$ROOT_DIR/.git" -prune -o -type f -name '.DS_Store' -delete

echo "Removed .build/, dist/, and .DS_Store files."
