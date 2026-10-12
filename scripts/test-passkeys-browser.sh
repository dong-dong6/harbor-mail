#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JAR="${1:-$ROOT/dist/mail-client.jar}"
test -f "$JAR"
RUN="$(mktemp -d)"
PORT="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
)"
mkdir -p "$ROOT/test-results"
java -jar "$JAR" --spring.profiles.active=demo --server.port="$PORT" \
  --mail.allowed-origin="http://localhost:$PORT" --mail.worker-enabled=false \
  --spring.datasource.url="jdbc:h2:file:$RUN/db;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;DEFAULT_NULL_ORDERING=HIGH" \
  > "$RUN/server.log" 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true' EXIT
ready=false
for i in $(seq 1 150); do
  if curl -sf "http://localhost:$PORT/api/v1/health" > /dev/null; then ready=true; break; fi
  kill -0 "$PID" 2>/dev/null || { cat "$RUN/server.log"; exit 1; }
  sleep .2
done
"$ready" || { cat "$RUN/server.log"; exit 1; }
node "$ROOT/client/tool/test_passkeys_browser.cjs" "http://localhost:$PORT/api/v1" \
  | tee "$ROOT/test-results/passkeys-browser.json"
