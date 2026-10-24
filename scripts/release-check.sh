#!/bin/bash
# Release check: "never wrong, and at least everything reference finds".
# Reruns the reference's uninstall leftover finder (read-only, the same steps `mo uninstall` previews) for every
# installed app, re-records what Sapu's finder sees on this Mac into Tests/parity-fixture.json (the hand
# review in it is kept), then fails if
#   - reference finds a path Sapu doesn't, and it isn't on the written reference-mistakes list,
#   - Sapu claims a path nobody has reviewed, or
#   - two apps claim the same path (or one inside the other).
# `sapu-cli selftest` replays the saved recording, so CI catches regressions without reference.
# Usage: scripts/release-check.sh            (about 7 minutes for 60 apps)
#        scripts/release-check.sh --todo     also print what needs a decision, as JSON
#        scripts/release-check.sh --tested <cask.json> <tested-apps.txt>
#            also rerun reference on the reference's tested apps, all installed side by side in a fake home folder that holds
#            exactly their Homebrew-documented leftovers (about 35 minutes for 628 apps). cask.json is
#            https://formulae.brew.sh/api/cask.json; tested-apps.txt lists one app name per line.
set -euo pipefail
cd "$(dirname "$0")/.."
REF_HOME="$(brew --prefix reference 2>/dev/null)/libexec"
[ -f "$REF_HOME/lib/core/common.sh" ] || { echo "reference isn't installed (brew install reference)."; exit 2; }
REF_VERSION=$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$(brew --prefix reference)/libexec/reference" 2>/dev/null || true)
[ -n "$REF_VERSION" ] || REF_VERSION=$(mo --version 2>/dev/null | awk '/version/{print $3; exit}')

scripts/build.sh release >/dev/null
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
build/sapu-cli apps --no-size > "$WORK/apps.tsv"

# One app's leftovers the way the reference's batch uninstall finds them: find_app_files, the user's crash
# reports, minus whatever the reference's uninstall protection drops. System folders are out of scope (outside $HOME).
cat > "$WORK/reference-one.sh" <<'ONE'
set +eu
SCRIPT_DIR="$REF_HOME"
source "$SCRIPT_DIR/lib/core/common.sh"
source "$SCRIPT_DIR/lib/uninstall/batch.sh" 2>/dev/null
files=$(REF_UNINSTALL_SIBLING_SURVIVES=0 find_app_files "$1" "$2" "$3" 2>/dev/null)
diag=$(get_diagnostic_report_paths_for_app "$3" "$2" "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null)
printf '%s\n%s\n' "$files" "$diag" | while IFS= read -r p; do
  [ -n "$p" ] || continue
  if REF_UNINSTALL_MODE=1 should_protect_path "$p" 2>/dev/null; then echo "PROTECTED $p"; else echo "$p"; fi
done
ONE
n=0; total=$(wc -l < "$WORK/apps.tsv" | tr -d ' ')
while IFS=$'\t' read -r name id _ path; do
  n=$((n + 1)); printf '\r\033[K  reference %d/%d  %s' "$n" "$total" "$name" >&2
  echo "### $name|$id|$path" >> "$WORK/reference.txt"
  (cd ~ && REF_HOME="$REF_HOME" nice -n 10 /bin/bash "$WORK/reference-one.sh" "$id" "$name" "$path" </dev/null >> "$WORK/reference.txt" 2>/dev/null)
done < "$WORK/apps.tsv"
echo >&2

status=0
build/sapu-cli parity record "$WORK/reference.txt" --version "${REF_VERSION:-?}" || status=$?

if [ "${1:-}" = "--tested" ]; then
  FAKE="$WORK/tested"; mkdir -p "$FAKE"
  build/sapu-cli coverage "$2" "$3" --export "$FAKE" >/dev/null
  n=0; total=$(wc -l < "$FAKE/apps.tsv" | tr -d ' ')
  while IFS=$'\t' read -r name id _ path; do
    n=$((n + 1)); printf '\r\033[K  reference (tested) %d/%d  %s' "$n" "$total" "$name" >&2
    echo "### $name|$id|$path" >> "$FAKE/reference.txt"
    (cd "$FAKE/home" && HOME="$FAKE/home" REF_HOME="$REF_HOME" nice -n 15 /bin/bash "$WORK/reference-one.sh" "$id" "$name" "$path" </dev/null 2>/dev/null \
      | grep -F "$FAKE/home/" | sed "s#^$FAKE/home#~#; s#^PROTECTED $FAKE/home#PROTECTED ~#" >> "$FAKE/reference.txt")
  done < "$FAKE/apps.tsv"
  echo >&2
  build/sapu-cli tested-record "$FAKE" "$FAKE/reference.txt" --version "${REF_VERSION:-?}" || status=$?
fi
[ "${1:-}" = "--todo" ] && build/sapu-cli parity todo
exit $status
