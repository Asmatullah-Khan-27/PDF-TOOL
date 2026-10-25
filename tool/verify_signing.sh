#!/usr/bin/env bash
# Verifies that a built APK/AAB is correctly signed for store upload.
#
# Usage:
#   tool/verify_signing.sh build/app/outputs/bundle/playRelease/app-play-release.aab
#   tool/verify_signing.sh build/app/outputs/flutter-apk/app-play-release.apk
#
# Exits non-zero if the artifact is missing, signed with the Android debug key,
# or (for an AAB) not signed at all.
#
# This script never creates or modifies credentials.

set -uo pipefail

artifact="${1:-}"
if [[ -z "$artifact" ]]; then
  echo "usage: $0 <path-to.apk-or.aab>" >&2
  exit 2
fi
if [[ ! -f "$artifact" ]]; then
  echo "FAIL: artifact not found: $artifact" >&2
  exit 2
fi

sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
build_tools="$(ls -d "$sdk"/build-tools/*/ 2>/dev/null | sort -V | tail -1)"

echo "artifact : $artifact"
echo "size     : $(stat -c%s "$artifact") bytes"
echo

case "$artifact" in
  *.aab)
    jarsigner="$(command -v jarsigner || echo "${JAVA_HOME:-}/bin/jarsigner")"
    if [[ ! -x "$jarsigner" ]]; then
      echo "FAIL: jarsigner not found (install a JDK)" >&2
      exit 2
    fi
    out="$("$jarsigner" -verify -verbose -certs "$artifact" 2>&1)"
    if grep -q "jar is unsigned" <<<"$out"; then
      echo "FAIL: the AAB is unsigned. Configure android/key.properties and rebuild."
      exit 1
    fi
    if grep -q "CN=Android Debug" <<<"$out"; then
      echo "FAIL: signed with the Android DEBUG key — no store will accept this."
      echo "      Create your upload keystore and rebuild (docs/SIGNING_AND_RELEASE.md)."
      exit 1
    fi
    echo "OK: AAB is signed."
    grep -m1 -E "X\.509|CN=" <<<"$out" || true
    ;;

  *.apk)
    apksigner="${build_tools}apksigner"
    if [[ ! -x "$apksigner" ]]; then
      echo "FAIL: apksigner not found under $sdk/build-tools" >&2
      exit 2
    fi
    if ! "$apksigner" verify "$artifact"; then
      echo "FAIL: APK signature does not verify."
      exit 1
    fi
    certs="$("$apksigner" verify --print-certs "$artifact" 2>&1)"
    if grep -q "CN=Android Debug" <<<"$certs"; then
      echo "FAIL: signed with the Android DEBUG key — installable, but NOT uploadable."
      echo "      Create your upload keystore and rebuild (docs/SIGNING_AND_RELEASE.md)."
      exit 1
    fi
    echo "OK: APK signature verifies and is not the debug key."
    grep -m1 "certificate DN" <<<"$certs" || true
    ;;

  *)
    echo "FAIL: expected a .apk or .aab, got: $artifact" >&2
    exit 2
    ;;
esac
