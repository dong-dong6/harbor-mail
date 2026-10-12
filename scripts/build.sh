#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
VERSION="$(python3 "$ROOT/scripts/check-version.py")"
command -v flutter >/dev/null || { echo 'Install Flutter stable and put flutter on PATH.' >&2; exit 1; }
command -v mvn >/dev/null || { echo 'Install Maven 3.9+ and Java 21.' >&2; exit 1; }
(cd "$ROOT/client" && flutter pub get && flutter analyze && flutter test && flutter build web --release --no-web-resources-cdn)
mkdir -p "$ROOT/server/src/main/resources/static" "$ROOT/dist"
python3 "$ROOT/scripts/test-prepare-web-assets.py"
python3 "$ROOT/scripts/prepare-web-assets.py" "$ROOT"
(cd "$ROOT/server" && mvn -B "${MAVEN_FLAGS[@]}" clean verify)
cp "$ROOT/server/target/mail-server-$VERSION.jar" "$ROOT/dist/mail-client.jar"
echo "Built $ROOT/dist/mail-client.jar (includes Flutter web)."
