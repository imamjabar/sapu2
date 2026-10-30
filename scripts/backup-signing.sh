#!/bin/bash
# Make an encrypted copy of ~/.sapu-signing, to keep somewhere other than this Mac (a password manager, an
# encrypted drive, a private cloud folder). Losing these files means every user must add Sapu2 to Full Disk Access again.
#
# Usage: scripts/backup-signing.sh <output-folder>
# It asks for a passphrase twice and writes <output-folder>/sapu-signing-YYYYMMDD.tar.enc.
# Restore:  openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in sapu-signing-YYYYMMDD.tar.enc | tar -x -C ~
# Nothing leaves this Mac and the passphrase is never stored.
set -euo pipefail
DIR="$HOME/.sapu-signing"
OUT="${1:-}"
[ -n "$OUT" ] || { echo "usage: $0 <output-folder>"; exit 2; }
[ -d "$DIR" ] || { echo "No $DIR folder found."; exit 1; }
mkdir -p "$OUT"
FILE="$OUT/sapu-signing-$(date +%Y%m%d).tar.enc"
[ ! -e "$FILE" ] || { echo "$FILE already exists."; exit 1; }
tar -c -C "$HOME" .sapu-signing | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -out "$FILE"
chmod 600 "$FILE"
# Prove the copy opens before anyone relies on it.
if openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in "$FILE" 2>/dev/null | tar -t >/dev/null 2>&1; then
  echo "Backup written and checked: $FILE"
else
  echo "Could not read the backup back (wrong passphrase on the check?). Delete $FILE and try again."; rm -f "$FILE"; exit 1
fi
