#!/usr/bin/env bash
# Exercise the actual compiled Flutter app with a disposable virtual passkey.
# No real account, external RP, production DB, or physical authenticator allowed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JAR="${1:-$ROOT/dist/mail-client.jar}"
test -f "$JAR"
# Fail before startup if an API-only package was supplied by mistake.
CONTENTS="$(jar tf "$JAR")"
grep -Fqx 'BOOT-INF/classes/static/main.dart.js' <<< "$CONTENTS"
grep -Fqx 'BOOT-INF/classes/static/vendor/passkeys/bundle-2.4.0.js' <<< "$CONTENTS"
RUN="$(mktemp -d)"
PORT="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
)"
mkdir -p "$ROOT/test-results/passkeys-flutter-browser"
java -jar "$JAR" --spring.profiles.active=demo --server.address=127.0.0.1 --server.port="$PORT" \
  --mail.allowed-origin="http://localhost:$PORT" --mail.worker-enabled=false \
  --spring.datasource.url="jdbc:h2:file:$RUN/db;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;DEFAULT_NULL_ORDERING=HIGH" \
  > "$RUN/server.log" 2>&1 &
PID=$!
cleanup() {
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  rm -rf "$RUN"
}
trap cleanup EXIT
ready=false
for i in $(seq 1 150); do
  if curl -sf "http://localhost:$PORT/api/v1/health" > /dev/null; then ready=true; break; fi
  kill -0 "$PID" 2>/dev/null || { cat "$RUN/server.log"; exit 1; }
  sleep .2
done
"$ready" || { cat "$RUN/server.log"; exit 1; }
node "$ROOT/client/tool/test_passkeys_flutter_browser.cjs" "http://localhost:$PORT" \
  | tee "$ROOT/test-results/passkeys-flutter-browser.json"
