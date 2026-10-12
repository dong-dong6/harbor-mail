#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT
javac --release 17 -d "$build" \
  "$here/../app/src/main/java/dev/harbor/harbor_mail/UpdatePolicy.java" \
  "$here/UpdatePolicySelfTest.java"
java -cp "$build" dev.harbor.harbor_mail.UpdatePolicySelfTest
