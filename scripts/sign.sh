#!/bin/bash
# Sign an app bundle with Sapu2's own self-signed certificate, so every build has the same code identity.
# macOS keys Full Disk Access to that identity: ad-hoc builds get a new identity per build (a hash of the binary),
# so the switch in System Settings stops applying after every update. A fixed certificate keeps it on.
#
# Usage: scripts/sign.sh <App.app>
# The certificate comes from SAPU_SIGN_P12 (a .p12 file, or its base64 text in CI) and SAPU_SIGN_PASS,
# else from ~/.sapu-signing/. Without either, the bundle is ad-hoc signed as before.
set -euo pipefail
APP="$1"
DIR="$HOME/.sapu-signing"
P12="${SAPU_SIGN_P12:-$DIR/sapu-signing.p12}"
PASS="${SAPU_SIGN_PASS:-$(cat "$DIR/p12.pass" 2>/dev/null || true)}"
# A secret pasted or piped into CI often carries a trailing newline; the password never contains one.
PASS="$(printf %s "$PASS" | tr -d '\r\n')"

if [ -n "$P12" ] && [ ! -f "$P12" ] && [ -n "${SAPU_SIGN_P12:-}" ]; then
  # CI passes the certificate as base64 text.
  TMP_P12="$(mktemp -t sapu-p12)"
  printf %s "$SAPU_SIGN_P12" | tr -d ' \t\r\n' | base64 --decode > "$TMP_P12"
  P12="$TMP_P12"
  # A PKCS#12 file is a DER sequence: it starts with byte 0x30. Say so here rather than inside the keychain import.
  [ "$(head -c 1 "$P12" | xxd -p)" = "30" ] || { echo "SAPU_SIGN_P12 is not base64 of a .p12 file ($(wc -c < "$P12" | tr -d ' ') bytes decoded)"; exit 1; }
fi

if [ ! -f "$P12" ] || [ -z "$PASS" ]; then
  echo "→ ad-hoc sign (no Sapu2 certificate found: Full Disk Access resets with each build)"
  codesign --force --deep --sign - --timestamp=none "$APP"
  codesign --verify --strict "$APP"
  exit 0
fi

# A throwaway keychain holds the certificate only while signing. codesign only finds identities in the search list,
# so it joins the list for the signing step and the original list is restored afterwards.
KC="$(mktemp -d)/sapu-sign.keychain-db"
KCPASS="$(openssl rand -hex 12)"
OLD_LIST=()
while IFS= read -r k; do OLD_LIST+=("$(echo "$k" | sed -e 's/^ *"//' -e 's/"$//')"); done < <(security list-keychains -d user)
cleanup() {
  security list-keychains -d user -s ${OLD_LIST[@]+"${OLD_LIST[@]}"} 2>/dev/null || true
  security delete-keychain "$KC" 2>/dev/null || true
  rm -f "${TMP_P12:-}"
}
trap cleanup EXIT
security create-keychain -p "$KCPASS" "$KC"
security list-keychains -d user -s ${OLD_LIST[@]+"${OLD_LIST[@]}"} "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security import "$P12" -f pkcs12 -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null
ID="$(security find-identity -p codesigning "$KC" | awk '/Sapu Self-Signed/ {print $2; exit}')"
[ -n "$ID" ] || { echo "Sapu2 certificate not usable for code signing"; exit 1; }

echo "→ sign with Sapu2 certificate ($ID)"
codesign --force --deep --sign "$ID" --keychain "$KC" --timestamp=none "$APP"
codesign --verify --strict "$APP"
