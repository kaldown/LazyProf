#!/bin/bash
# Runs every headless suite (scripts/test_*.lua) with lua5.1, then parse-checks
# every Lua file under Core, Modules and Professions with luac5.1.
# Run from anywhere; the script switches to the repo root.
set -e
cd "$(dirname "$0")/.."

suites=0
for t in scripts/test_*.lua; do
    echo "== $t"
    lua5.1 "$t"
    suites=$((suites + 1))
done

files=0
while IFS= read -r f; do
    luac5.1 -p "$f"
    files=$((files + 1))
done < <(find Core Modules Professions -name '*.lua' | sort)

echo "OK: $suites suites passed, $files files parse-checked"
