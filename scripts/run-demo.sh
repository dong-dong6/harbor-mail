#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ ! -f dist/mail-client.jar && -f dist/mail-client.jar.part001 ]]; then bash scripts/assemble-runtime.sh; fi
test -f dist/mail-client.jar || { echo 'Run scripts/build.sh first, or extract all runtime parts.' >&2; exit 1; }
echo 'LOCAL SYNTHETIC DEMO ONLY: http://127.0.0.1:8080'
echo 'Demo login: demo / demo-local-only. No provider mail is sent.'
exec java -jar dist/mail-client.jar --spring.profiles.active=demo --server.address=127.0.0.1 "$@"
