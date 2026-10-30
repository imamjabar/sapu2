#!/bin/bash
# Release check: "never wrong, and at least everything the reference cleaner finds".
# Reruns the reference cleaner's uninstall leftover finder (read-only, the same steps its uninstall preview
# runs) for every installed app, re-records what Sapu2's finder sees on this Mac into Tests/parity-fixture.json
# (the hand review in it is kept), then fails if
#   - the reference finds a path Sapu2 doesn't, and it isn't on the written reference-mistakes list,
#   - Sapu2 claims a path nobody has reviewed, or
#   - two apps claim the same path (or one inside the other).
# `sapu2-cli selftest` replays the saved recording, so CI catches regressions without the reference tool.
# Usage: scripts/release-check.sh            (about 7 minutes for 60 apps)
#        scripts/release-check.sh --todo     also print what needs a decision, as JSON
#        scripts/release-check.sh --tested <cask.json> <tested-apps.txt>
#            also rerun the reference on its tested apps, all installed side by side in a fake home folder that
#            holds exactly their Homebrew-documented leftovers (about 35 minutes for 628 apps). cask.json is
#            https://formulae.brew.sh/api/cask.json; tested-apps.txt lists one app name per line.
set -euo pipefail
cd "$(dirname "$0")/.."
# The reference cleaner's Homebrew formula: $REF_FORMULA, or the first line of scripts/.reference (not committed).
# Its own settings are environment variables named after it in capitals (PREFIX_UNINSTALL_MODE and so on).
REF_FORMULA="${REF_FORMULA:-$(head -n 1 scripts/.reference 2>/dev/null || true)}"
[ -n "$REF_FORMULA" ] || { echo "Name the reference cleaner's Homebrew formula: REF_FORMULA=<name> $0, or put it in scripts/.reference."; exit 2; }
REF_CMD="${REF_CMD:-$REF_FORMULA}"; REF_PREFIX=$(printf %s "$REF_FORMULA" | tr '[:lower:]-' '[:upper:]_')
REF_HOME="$(brew --prefix "$REF_FORMULA" 2>/dev/null)/libexec"
[ -f "$REF_HOME/lib/core/common.sh" ] || { echo "The reference cleaner isn't installed (brew install $REF_FORMULA)."; exit 2; }
REF_VERSION=$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$REF_HOME/$REF_FORMULA" 2>/dev/null || true)
[ -n "$REF_VERSION" ] || REF_VERSION=$("$REF_CMD" --version 2>/dev/null | awk '/version/{print $3; exit}')

scripts/build.sh release >/dev/null
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# Neither the reference tool's own app nor Sapu2 itself is an app to check.
build/sapu2-cli apps --no-size | grep -vi -e "$REF_FORMULA" -e "app.sapu2.Sapu2" -e "app.sapu.Sapu" > "$WORK/apps.tsv" || true

# One app's leftovers the way the reference's batch uninstall finds them: find_app_files, the user's crash
# reports, minus whatever its uninstall protection drops. System folders are out of scope (outside $HOME).
cat > "$WORK/reference-one.sh" <<'ONE'
set +eu
SCRIPT_DIR="$REF_HOME"
source "$SCRIPT_DIR/lib/core/common.sh"
source "$SCRIPT_DIR/lib/uninstall/batch.sh" 2>/dev/null
files=$(export "${REF_PREFIX}_UNINSTALL_SIBLING_SURVIVES=0"; find_app_files "$1" "$2" "$3" 2>/dev/null)
diag=$(get_diagnostic_report_paths_for_app "$3" "$2" "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null)
printf '%s\n%s\n' "$files" "$diag" | while IFS= read -r p; do
  [ -n "$p" ] || continue
  if (export "${REF_PREFIX}_UNINSTALL_MODE=1"; should_protect_path "$p" 2>/dev/null); then echo "PROTECTED $p"; else echo "$p"; fi
done
ONE
n=0; total=$(wc -l < "$WORK/apps.tsv" | tr -d ' ')
while IFS=$'\t' read -r name id _ path; do
  n=$((n + 1)); printf '\r\033[K  reference %d/%d  %s' "$n" "$total" "$name" >&2
  echo "### $name|$id|$path" >> "$WORK/reference.txt"
  (cd ~ && REF_HOME="$REF_HOME" REF_PREFIX="$REF_PREFIX" nice -n 10 /bin/bash "$WORK/reference-one.sh" "$id" "$name" "$path" </dev/null >> "$WORK/reference.txt" 2>/dev/null)
done < "$WORK/apps.tsv"
echo >&2

status=0
build/sapu2-cli parity record "$WORK/reference.txt" --version "${REF_VERSION:-?}" --forget "$REF_FORMULA" --forget app.sapu2.Sapu2 --forget app.sapu.Sapu || status=$?

if [ "${1:-}" = "--tested" ]; then
  FAKE="$WORK/tested"; mkdir -p "$FAKE"
  build/sapu2-cli coverage "$2" "$3" --export "$FAKE" >/dev/null
  n=0; total=$(wc -l < "$FAKE/apps.tsv" | tr -d ' ')
  while IFS=$'\t' read -r name id _ path; do
    n=$((n + 1)); printf '\r\033[K  reference (tested) %d/%d  %s' "$n" "$total" "$name" >&2
    echo "### $name|$id|$path" >> "$FAKE/reference.txt"
    (cd "$FAKE/home" && HOME="$FAKE/home" REF_HOME="$REF_HOME" REF_PREFIX="$REF_PREFIX" nice -n 15 /bin/bash "$WORK/reference-one.sh" "$id" "$name" "$path" </dev/null 2>/dev/null \
      | grep -F "$FAKE/home/" | sed "s#^$FAKE/home#~#; s#^PROTECTED $FAKE/home#PROTECTED ~#" >> "$FAKE/reference.txt")
  done < "$FAKE/apps.tsv"
  echo >&2
  build/sapu2-cli tested-record "$FAKE" "$FAKE/reference.txt" --version "${REF_VERSION:-?}" || status=$?
fi
[ "${1:-}" = "--todo" ] && build/sapu2-cli parity todo
exit $status
