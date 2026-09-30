#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
target="$ROOT/dist/mail-client.jar"
if [[ -f "$target" ]]; then exit 0; fi
for n in 001 002 003 004; do
  test -f "$target.part$n" || { echo "Missing runtime part $n. Extract all four runtime archives into the same folder as the source archive." >&2; exit 1; }
done
temp="$(mktemp "$ROOT/dist/runtime.XXXXXX")"
trap 'rm -f "$temp"' EXIT
cat "$target.part001" "$target.part002" "$target.part003" "$target.part004" > "$temp"
expected="$(awk '{print $1}' "$ROOT/dist/runtime.sha256")"
if command -v sha256sum >/dev/null; then actual="$(sha256sum "$temp" | awk '{print $1}')"; else actual="$(shasum -a 256 "$temp" | awk '{print $1}')"; fi
[[ "$actual" == "$expected" ]] || { echo 'Runtime checksum mismatch; do not run it. Download the parts again.' >&2; exit 1; }
mv "$temp" "$target"
echo 'Runtime assembled and SHA-256 verified.'
