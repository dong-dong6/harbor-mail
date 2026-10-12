#!/usr/bin/env bash
# Build THIS checkout's development APK with an already provisioned official SDK.
# Never install SDK components, accept licenses, or persist a production signing key.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
: "${SDK:?An already provisioned Android SDK is required}"
export ANDROID_HOME="$SDK" ANDROID_SDK_ROOT="$SDK"
export HARBOR_ANDROID_NDK_VERSION="${HARBOR_ANDROID_NDK_VERSION:-29.0.14206865}"
export HARBOR_ANDROID_CMAKE_VERSION="${HARBOR_ANDROID_CMAKE_VERSION:-3.31.5}"
CMAKE_BIN="$SDK/cmake/$HARBOR_ANDROID_CMAKE_VERSION/bin/cmake"
BUILD_TOOLS="$SDK/build-tools/36.0.0"
for prerequisite in "$SDK/platforms/android-36/android.jar" \
  "$SDK/platforms/android-35/android.jar" "$CMAKE_BIN" \
  "$SDK/ndk/$HARBOR_ANDROID_NDK_VERSION/source.properties" \
  "$SDK/licenses/android-sdk-license" "$BUILD_TOOLS/aapt" "$BUILD_TOOLS/apksigner"; do
  test -s "$prerequisite" || { echo 'Required preinstalled Android SDK component/license is missing. Provision it explicitly before retrying.' >&2; exit 1; }
done
test -x "$BUILD_TOOLS/aapt" && test -x "$BUILD_TOOLS/apksigner" && test -x "$CMAKE_BIN"
# Keep a log of exact tools; no SDK manager or license-writing commands are used.
"$BUILD_TOOLS/aapt" version
"$BUILD_TOOLS/apksigner" version
"$CMAKE_BIN" --version
cat "$SDK/ndk/$HARBOR_ANDROID_NDK_VERSION/source.properties"
VERSION="$(python3 "$ROOT/scripts/check-version.py")"
VERSION_CODE="$(python3 - "$ROOT/client/pubspec.yaml" <<'PY'
import pathlib,re,sys
m=re.search(r'^version:\s*[0-9]+\.[0-9]+\.[0-9]+\+([0-9]+)\s*$', pathlib.Path(sys.argv[1]).read_text(), re.M)
if not m: raise SystemExit('pubspec.yaml must include an Android build number')
print(m[1])
PY
)"
SOURCE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]; then
  echo 'Build the committed checkout only; a dirty tree cannot claim an exact source commit.' >&2; exit 1
fi
if [ -n "${GITHUB_SHA:-}" ] && [ "$SOURCE_COMMIT" != "$GITHUB_SHA" ]; then
  echo 'Checkout does not match the current CI source commit' >&2; exit 1
fi
python3 "$ROOT/scripts/test-prepare-android-download.py"
(cd "$ROOT/client" && flutter pub get --enforce-lockfile && flutter build apk --debug --no-pub)
python3 "$ROOT/scripts/prepare-android-download.py" \
  --apk "$ROOT/client/build/app/outputs/flutter-apk/app-debug.apk" \
  --destination "$ROOT/server/src/main/resources/META-INF/android-download" \
  --aapt "$BUILD_TOOLS/aapt" --apksigner "$BUILD_TOOLS/apksigner" \
  --version-name "$VERSION" --version-code "$VERSION_CODE" --source-commit "$SOURCE_COMMIT"
