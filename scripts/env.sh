#!/usr/bin/env bash
# Source this file. Toolchains in tools/ are development-only and not packaged.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
if [[ -d "$ROOT/tools/flutter" ]]; then
  export HOME="$ROOT/tools/sdk-home"
  export XDG_CONFIG_HOME="$HOME/.config"
  export PUB_CACHE="$ROOT/tools/pub-cache"
  mkdir -p "$XDG_CONFIG_HOME" "$PUB_CACHE"
  export PATH="$ROOT/tools/flutter/bin:$PATH"
fi
if [[ -d "$ROOT/tools/apache-maven-3.9.9" ]]; then
  export PATH="$ROOT/tools/apache-maven-3.9.9/bin:$PATH"
fi
MVN_REPO="${MAIL_MAVEN_REPO:-$ROOT/tools/m2}"
export ROOT MVN_REPO
if [[ -x "$ROOT/tools/jdk/usr/lib/jvm/java-21-openjdk-amd64/bin/java" ]]; then
  export JAVA_HOME="$ROOT/tools/jdk/usr/lib/jvm/java-21-openjdk-amd64"
  export PATH="$JAVA_HOME/bin:$PATH"
fi
MAVEN_FLAGS=("-Dmaven.repo.local=$MVN_REPO")
if [[ -n "${MAVEN_SETTINGS:-}" ]]; then
  MAVEN_FLAGS+=("-s" "$MAVEN_SETTINGS")
elif [[ -n "${HTTPS_PROXY:-${https_proxy:-}}" ]]; then
  # Some managed environments issue a per-command proxy address. Generate fresh
  # runtime-only Maven settings, never re-use an expired address or ship it.
  _mail_maven_settings="$(python3 "$ROOT/scripts/maven-proxy-settings.py" "$ROOT/tools")"
  MAVEN_FLAGS+=("-s" "$_mail_maven_settings")
fi
