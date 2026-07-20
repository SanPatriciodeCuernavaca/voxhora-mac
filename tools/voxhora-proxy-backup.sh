#!/usr/bin/env bash
#
# voxhora-proxy-backup.sh — nightly offsite pull of the LLM proxy's SQLite
# database (2026-07-19, weekly-review #1). Every attorney's AI token + spend
# history lives on ONE Fly volume; this script curls /admin/backup (a
# VACUUM'd consistent snapshot) into ~/Voxhora_Backups/proxy/, verifies it
# is a readable SQLite db with a populated tokens table, and keeps the last
# 30 days. Runs from launchd (com.voxhora.proxybackup, daily 06:20).
#
# Auth: the admin secret at ~/.voxhora_admin_secret (same as the watchdog).
#
set -uo pipefail

PROXY_URL="${VOXHORA_PROXY_URL:-https://voxhora-llm-proxy.fly.dev}"
DEST_DIR="$HOME/Voxhora_Backups/proxy"
LOG="$HOME/Voxhora_Logs/proxy-backup.log"
STAMP="$(date +%Y%m%d)"
OUT="$DEST_DIR/voxhora-proxy-$STAMP.db"
KEEP_DAYS=30

mkdir -p "$DEST_DIR" "$(dirname "$LOG")"

say() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

SECRET_FILE="$HOME/.voxhora_admin_secret"
if [ ! -f "$SECRET_FILE" ]; then
  say "FATAL: $SECRET_FILE missing — cannot authenticate"; exit 1
fi
SEC="$(cat "$SECRET_FILE")"

TMP="$(mktemp /tmp/voxhora-proxy-backup.XXXXXX)"
HTTP_CODE="$(curl -sS -m 120 -o "$TMP" -w '%{http_code}' \
  -H "X-Voxhora-Admin: $SEC" "$PROXY_URL/admin/backup" 2>>"$LOG")"

if [ "$HTTP_CODE" != "200" ]; then
  say "FATAL: /admin/backup returned HTTP $HTTP_CODE"; rm -f "$TMP"; exit 1
fi

# Verify it's a real SQLite db with tokens in it before trusting it.
TOKENS="$(sqlite3 "file:$TMP?mode=ro" "SELECT COUNT(*) FROM tokens;" 2>>"$LOG")" || {
  say "FATAL: downloaded file is not a readable SQLite db"; rm -f "$TMP"; exit 1
}
if [ -z "$TOKENS" ] || [ "$TOKENS" -lt 1 ]; then
  say "FATAL: backup has $TOKENS tokens — refusing to keep an empty snapshot"
  rm -f "$TMP"; exit 1
fi
INTEGRITY="$(sqlite3 "file:$TMP?mode=ro" "PRAGMA integrity_check;" 2>>"$LOG")"
if [ "$INTEGRITY" != "ok" ]; then
  say "FATAL: integrity_check said: $INTEGRITY"; rm -f "$TMP"; exit 1
fi

mv "$TMP" "$OUT"
SIZE="$(stat -f%z "$OUT")"
say "OK: $OUT ($SIZE bytes, $TOKENS tokens, integrity ok)"

# Rotate: keep the newest $KEEP_DAYS snapshots (mv-to-trash-free is fine here —
# these are our own generated copies, and newer ones supersede them).
ls -1t "$DEST_DIR"/voxhora-proxy-*.db 2>/dev/null | tail -n +$((KEEP_DAYS + 1)) | while read -r old; do
  rm -f "$old" && say "rotated out $old"
done

exit 0
