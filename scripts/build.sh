#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
VERSION="$(python3 "$ROOT/scripts/check-version.py")"
command -v flutter >/dev/null || { echo 'Install Flutter stable and put flutter on PATH.' >&2; exit 1; }
command -v mvn >/dev/null || { echo 'Install Maven 3.9+ and Java 21.' >&2; exit 1; }
(cd "$ROOT/client" && flutter pub get && flutter analyze && flutter test && flutter build web --release --no-web-resources-cdn)
mkdir -p "$ROOT/server/src/main/resources/static" "$ROOT/dist"
# This directory contains generated build output only.
python3 - "$ROOT" <<'PY'
import pathlib,shutil,sys
r=pathlib.Path(sys.argv[1]); dst=r/'server/src/main/resources/static'
for p in dst.iterdir():
    if p.is_dir(): shutil.rmtree(p)
    else: p.unlink()
shutil.copytree(r/'client/build/web',dst,dirs_exist_ok=True)
PY
(cd "$ROOT/server" && mvn -B "${MAVEN_FLAGS[@]}" clean verify)
cp "$ROOT/server/target/mail-server-$VERSION.jar" "$ROOT/dist/mail-client.jar"
echo "Built $ROOT/dist/mail-client.jar (includes Flutter web)."
